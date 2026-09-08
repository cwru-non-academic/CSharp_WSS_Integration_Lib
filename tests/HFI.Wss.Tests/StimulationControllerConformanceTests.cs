using NUnit.Framework;
using Wss.CoreModule;
using Wss.Testing;

namespace HFI.Wss.Tests;

[TestFixture]
public sealed class StimulationControllerConformanceTests
{
    private const int InitializationPollLimit = 3000;
    private const int OperationPollLimit = 2000;

    [Test]
    public async Task InitializationThroughHfiPassesCoreConformance()
    {
        string fixtureDirectory = CreateFixtureDirectory();
        try
        {
            using var controller = CreateController(fixtureDirectory);

            IWssConformance conformance = await InitializeUntilStreamingAsync(controller);
            InitializationConformanceResult result = conformance.ValidateInitialization();

            Assert.That(result.Passed, Is.True, string.Join(Environment.NewLine, result.Failures));
        }
        finally
        {
            DeleteFixtureDirectory(fixtureDirectory);
        }
    }

    [Test]
    public async Task AnalogStimulationThroughHfiPassesCoreConformance()
    {
        string fixtureDirectory = CreateFixtureDirectory();
        try
        {
            using var controller = CreateController(fixtureDirectory);
            IWssConformance conformance = await InitializeUntilStreamingAsync(controller);
            WssStimulationBaseline baseline = conformance.CaptureStimulationBaseline();

            controller.StimulateAnalog("thumb", 237, 4, 13);

            StimulationConformanceResult result = await WaitForStimulationAsync(
                conformance,
                baseline,
                pulseWidth: 237);
            Assert.That(result.Passed, Is.True, string.Join(Environment.NewLine, result.Failures));
        }
        finally
        {
            DeleteFixtureDirectory(fixtureDirectory);
        }
    }

    [Test]
    public async Task NormalizedStimulationThroughHfiPassesCoreConformance()
    {
        string fixtureDirectory = CreateFixtureDirectory();
        try
        {
            using var controller = CreateController(fixtureDirectory);
            IWssConformance conformance = await InitializeUntilStreamingAsync(controller);
            WssStimulationBaseline baseline = conformance.CaptureStimulationBaseline();

            controller.StimulateNormalized("thumb", 0.5f);

            StimulationConformanceResult result = await WaitForStimulationAsync(
                conformance,
                baseline,
                pulseWidth: 121);
            Assert.That(result.Passed, Is.True, string.Join(Environment.NewLine, result.Failures));
        }
        finally
        {
            DeleteFixtureDirectory(fixtureDirectory);
        }
    }

    [Test]
    public async Task RuntimeEventEditThroughHfiResumesConformantStreaming()
    {
        string fixtureDirectory = CreateFixtureDirectory();
        try
        {
            using var controller = CreateController(fixtureDirectory);
            IWssConformance conformance = await InitializeUntilStreamingAsync(controller);
            WssMessageObservation initialStream = conformance.MessageHistory.Last(IsStream);

            controller.UpdateIPD(targetWSS: 1, ipd: 51, eventID: 1);
            bool pausedAfterRequest = !controller.Started();

            WssMessageObservation? edit = null;
            WssMessageObservation? resumedStream = null;
            for (int i = 0; i < OperationPollLimit; i++)
            {
                IReadOnlyList<WssMessageObservation> history = conformance.MessageHistory;
                edit = history.FirstOrDefault(item =>
                    item.SequenceNumber > initialStream.SequenceNumber &&
                    item.Target == (byte)WssTarget.Wss1 &&
                    item.MessageId == (byte)WSSMessageIDs.EditEventConfig &&
                    item.Payload.Length >= 3 &&
                    item.Payload[2] == 1);
                if (edit != null)
                {
                    resumedStream = history.FirstOrDefault(item =>
                        item.SequenceNumber > edit.SequenceNumber && IsStream(item));
                }

                if (resumedStream != null && controller.Started())
                    break;

                await Task.Delay(1);
            }

            InitializationConformanceResult result = conformance.ValidateInitialization();
            Assert.Multiple(() =>
            {
                Assert.That(pausedAfterRequest, Is.True, "Core did not pause streaming for the Event edit.");
                Assert.That(edit, Is.Not.Null, "Core did not transmit EditEventConfig for the HFI UpdateIPD call.");
                Assert.That(resumedStream, Is.Not.Null, "Core did not resume streaming after the Event edit.");
                Assert.That(controller.Started(), Is.True, "Core did not return to streaming state.");
                Assert.That(result.Passed, Is.True, string.Join(Environment.NewLine, result.Failures));
            });
        }
        finally
        {
            DeleteFixtureDirectory(fixtureDirectory);
        }
    }

    private static StimulationController CreateController(string fixtureDirectory) =>
        new(new StimulationOptions
        {
            ConfigPath = fixtureDirectory,
            EmulatedConformanceMode = true,
            MaxSetupTries = 1,
            TickIntervalMs = 1
        });

    private static async Task<IWssConformance> InitializeUntilStreamingAsync(StimulationController controller)
    {
        controller.Initialize();
        Assert.That(controller.TryGetConformance(out IWssConformance conformance), Is.True,
            "HFI did not expose the emulator's Core conformance capability.");

        bool startedObserved = false;
        bool streamObserved = false;
        for (int i = 0; i < InitializationPollLimit; i++)
        {
            startedObserved = startedObserved || controller.Started();
            streamObserved = streamObserved || conformance.StimulationHistory.Count > 0;
            if (startedObserved && streamObserved)
                break;

            await Task.Delay(1);
        }

        Assert.Multiple(() =>
        {
            Assert.That(startedObserved, Is.True, "Core did not complete initialization within the finite poll limit.");
            Assert.That(streamObserved, Is.True, "Core did not emit a startup stream within the finite poll limit.");
        });
        return conformance;
    }

    private static async Task<StimulationConformanceResult> WaitForStimulationAsync(
        IWssConformance conformance,
        WssStimulationBaseline baseline,
        int pulseWidth)
    {
        var expectation = new WssStimulationExpectation(
            target: (byte)WssTarget.Wss1,
            channel: 1,
            pulseAmplitude: 4,
            pulseWidth: pulseWidth,
            interPulseInterval: 13,
            messageId: (byte)WSSMessageIDs.StreamChangeAll);

        StimulationConformanceResult result = conformance.ValidateStimulation(expectation, baseline);
        for (int i = 0; i < OperationPollLimit && !result.Passed; i++)
        {
            await Task.Delay(1);
            result = conformance.ValidateStimulation(expectation, baseline);
        }

        return result;
    }

    private static bool IsStream(WssMessageObservation observation) =>
        observation.MessageId >= (byte)WSSMessageIDs.StreamChangeAll &&
        observation.MessageId <= (byte)WSSMessageIDs.StreamChangeNoPA;

    private static string CreateFixtureDirectory()
    {
        string directory = Path.Combine(Path.GetTempPath(), $"hfi-wss-conformance-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        File.WriteAllText(
            Path.Combine(directory, "stimConfig.json"),
            "{\"maxWSS\":1,\"firmware\":\"J03\",\"broadcastTarget\":\"0x8F\"," +
            "\"wssTargets\":[\"0x81\",\"0x82\",\"0x83\"],\"useConfigAmpCurves\":true," +
            "\"ampCurves\":[{\"LowThreshold\":0.0,\"LowConst\":1.0,\"ExpPower\":1.0," +
            "\"LinearOffset\":-1.0,\"LinearSlope\":1.0}]}");
        File.WriteAllText(
            Path.Combine(directory, "stimParams.json"),
            "{\"stim\":{\"ch\":{\"1\":{\"ampMode\":\"PW\",\"minPW\":21,\"maxPW\":221," +
            "\"minPA\":0.0,\"maxPA\":0.0,\"defaultPA\":4.0,\"defaultPW\":50,\"IPI\":13}}}}");
        return directory;
    }

    private static void DeleteFixtureDirectory(string directory)
    {
        if (Directory.Exists(directory))
            Directory.Delete(directory, recursive: true);
    }
}
