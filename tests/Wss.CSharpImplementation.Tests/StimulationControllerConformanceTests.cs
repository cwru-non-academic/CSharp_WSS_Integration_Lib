using System.Globalization;
using System.Text.Json;
using NUnit.Framework;
using Wss.CoreModule;
using Wss.Testing;

namespace Wss.CSharpImplementation.Tests;

[TestFixture]
public sealed class StimulationControllerConformanceTests
{
    private const int InitializationPollLimit = 3000;
    private const int OperationPollLimit = 2000;
    private const int PostStopObservationPollLimit = 20;

    private static IEnumerable<TestCaseData> NormalizedScenarios =>
        WssBehaviorScenarios.NormalizedStimulation.Select(scenario =>
            new TestCaseData(scenario).SetName(scenario.Id));

    [Test]
    public async Task InitializationThroughCSharpImplementationPassesCoreConformance()
    {
        WssInitializationScenario scenario = WssBehaviorScenarios.Initialization;
        string fixtureDirectory = CreateFixtureDirectory();
        try
        {
            using var controller = CreateController(fixtureDirectory);

            IWssConformance conformance = await InitializeAsync(controller, scenario);
            InitializationConformanceResult result = conformance.ValidateInitialization();

            if (scenario.RequiresSuccessfulConformance)
                Assert.That(result.Passed, Is.True, string.Join(Environment.NewLine, result.Failures));
        }
        finally
        {
            DeleteFixtureDirectory(fixtureDirectory);
        }
    }

    [Test]
    public async Task AnalogStimulationThroughCSharpImplementationPassesCoreConformance()
    {
        WssAnalogStimulationScenario scenario = WssBehaviorScenarios.DirectAnalog;
        string fixtureDirectory = CreateFixtureDirectory();
        try
        {
            using var controller = CreateController(fixtureDirectory);
            IWssConformance conformance = await InitializeAsync(
                controller,
                WssBehaviorScenarios.Initialization);
            WssStimulationBaseline baseline = conformance.CaptureStimulationBaseline();

            controller.StimulateAnalog(
                MapChannel(scenario.Channel),
                scenario.PulseWidth,
                ToWrapperAmplitude(scenario.AmplitudeMa),
                scenario.InterPulseInterval);

            StimulationConformanceResult result = await WaitForStimulationAsync(
                conformance,
                baseline,
                scenario.Expectation);
            Assert.That(result.Passed, Is.True, string.Join(Environment.NewLine, result.Failures));
        }
        finally
        {
            DeleteFixtureDirectory(fixtureDirectory);
        }
    }

    [TestCaseSource(nameof(NormalizedScenarios))]
    public async Task NormalizedScenario(WssNormalizedStimulationScenario scenario)
    {
        string fixtureDirectory = CreateFixtureDirectory();
        try
        {
            using var controller = CreateController(fixtureDirectory);
            IWssConformance conformance = await InitializeAsync(
                controller,
                WssBehaviorScenarios.Initialization);
            WssStimulationBaseline baseline = conformance.CaptureStimulationBaseline();

            controller.StimulateNormalized(MapChannel(scenario.Channel), scenario.Input);

            StimulationConformanceResult result = await WaitForStimulationAsync(
                conformance,
                baseline,
                scenario.Expectation);
            Assert.That(result.Passed, Is.True, string.Join(Environment.NewLine, result.Failures));
        }
        finally
        {
            DeleteFixtureDirectory(fixtureDirectory);
        }
    }

    [Test]
    public async Task RuntimeEventEditThroughCSharpImplementationResumesConformantStreaming()
    {
        WssRuntimeEventEditScenario scenario = WssBehaviorScenarios.RuntimeEventEdit;
        string fixtureDirectory = CreateFixtureDirectory();
        try
        {
            using var controller = CreateController(fixtureDirectory);
            IWssConformance conformance = await InitializeAsync(
                controller,
                WssBehaviorScenarios.Initialization);
            WssMessageObservation initialStream = conformance.MessageHistory.Last(IsStream);

            controller.UpdateEventRatio(
                MapTarget(scenario.Target),
                scenario.Ratio,
                scenario.EventId);
            bool pausedAfterRequest = !controller.Started();

            WssMessageObservation? edit = null;
            WssMessageObservation? additionalSyncGroup = null;
            WssMessageObservation? resumedStream = null;
            for (int i = 0; i < OperationPollLimit; i++)
            {
                IReadOnlyList<WssMessageObservation> history = conformance.MessageHistory;
                edit = history.FirstOrDefault(item =>
                    item.SequenceNumber > initialStream.SequenceNumber &&
                    item.Target == scenario.Target &&
                    item.MessageId == scenario.ExpectedMessageId &&
                    item.Payload.Length >= 5 &&
                    item.Payload[2] == scenario.EventId &&
                    item.Payload[3] == scenario.ExpectedSubcommand &&
                    item.Payload[4] == scenario.ExpectedValue);
                additionalSyncGroup = history.FirstOrDefault(item =>
                    item.SequenceNumber > initialStream.SequenceNumber &&
                    item.MessageId == (byte)WSSMessageIDs.SyncGroup);
                if (edit != null)
                {
                    resumedStream = history.FirstOrDefault(item =>
                        item.SequenceNumber > edit.SequenceNumber && IsStream(item));
                }

                bool resumeStateMatches = scenario.ResumeStreamingExpected
                    ? resumedStream != null && controller.Started()
                    : resumedStream == null && !controller.Started();
                bool syncGroupStateMatches =
                    (additionalSyncGroup != null) == scenario.AdditionalSyncGroupExpected;
                if (edit != null && resumeStateMatches && syncGroupStateMatches)
                    break;

                await Task.Delay(1);
            }

            InitializationConformanceResult result = conformance.ValidateInitialization();
            Assert.Multiple(() =>
            {
                Assert.That(pausedAfterRequest, Is.True, "Core did not pause streaming for the Event edit.");
                Assert.That(edit, Is.Not.Null, "Core did not transmit the scenario's EditEventConfig metadata.");
                Assert.That(
                    additionalSyncGroup != null,
                    Is.EqualTo(scenario.AdditionalSyncGroupExpected),
                    "The Event edit SyncGroup behavior did not match the shared scenario.");
                Assert.That(
                    resumedStream != null,
                    Is.EqualTo(scenario.ResumeStreamingExpected),
                    "The Event edit stream resumption did not match the shared scenario.");
                Assert.That(
                    controller.Started(),
                    Is.EqualTo(scenario.ResumeStreamingExpected),
                    "The wrapper's streaming state did not match the shared scenario.");
                if (scenario.RequiresSuccessfulConformance)
                    Assert.That(result.Passed, Is.True, string.Join(Environment.NewLine, result.Failures));
            });
        }
        finally
        {
            DeleteFixtureDirectory(fixtureDirectory);
        }
    }

    [Test]
    public async Task StopStimulationThroughCSharpImplementationDoesNotResumeStreaming()
    {
        WssStopStimulationScenario scenario = WssBehaviorScenarios.StopStimulation;
        string fixtureDirectory = CreateFixtureDirectory();
        try
        {
            using var controller = CreateController(fixtureDirectory);
            IWssConformance conformance = await InitializeAsync(
                controller,
                WssBehaviorScenarios.Initialization);
            WssMessageObservation initialStream = conformance.MessageHistory.Last(IsStream);

            controller.StopStimulation(MapTarget(scenario.Target));

            WssMessageObservation? stop = null;
            long? stopCompletedSequence = null;
            for (int i = 0; i < OperationPollLimit; i++)
            {
                IReadOnlyList<WssMessageObservation> history = conformance.MessageHistory;
                stop = history.FirstOrDefault(item =>
                    item.SequenceNumber > initialStream.SequenceNumber &&
                    item.Target == scenario.Target &&
                    item.MessageId == scenario.ExpectedMessageId &&
                    item.Payload.Length >= 3 &&
                    item.Payload[2] == scenario.ExpectedOperationValue);
                if (stop != null && !controller.Started() && controller.Ready())
                {
                    IReadOnlyList<WssMessageObservation> completionHistory = conformance.MessageHistory;
                    stopCompletedSequence = completionHistory[^1].SequenceNumber;
                    break;
                }

                await Task.Delay(1);
            }

            bool startedAfterCompletion = false;
            for (int i = 0; i < PostStopObservationPollLimit; i++)
            {
                await Task.Delay(1);
                startedAfterCompletion = startedAfterCompletion || controller.Started();
            }

            IReadOnlyList<WssMessageObservation> finalHistory = conformance.MessageHistory;
            WssMessageObservation[] resumedStreams = stopCompletedSequence == null
                ? Array.Empty<WssMessageObservation>()
                : finalHistory
                    .Where(item => item.SequenceNumber > stopCompletedSequence && IsStream(item))
                    .ToArray();
            string diagnostics = BuildStopDiagnostics(
                finalHistory,
                stop,
                stopCompletedSequence,
                controller.Started());

            Assert.Multiple(() =>
            {
                Assert.That(stop, Is.Not.Null,
                    $"Core did not transmit the scenario's stop command.{Environment.NewLine}{diagnostics}");
                Assert.That(stopCompletedSequence, Is.Not.Null,
                    $"Stop did not reach the public completion boundary.{Environment.NewLine}{diagnostics}");
                Assert.That(
                    resumedStreams.Length > 0,
                    Is.EqualTo(scenario.ResumeStreamingExpected),
                    $"Post-stop streaming did not match the shared scenario.{Environment.NewLine}{diagnostics}");
                Assert.That(startedAfterCompletion, Is.EqualTo(scenario.ResumeStreamingExpected),
                    $"Streaming state changed after Stop completed.{Environment.NewLine}{diagnostics}");
                Assert.That(
                    controller.Started(),
                    Is.EqualTo(scenario.ResumeStreamingExpected),
                    $"The wrapper's post-stop state did not match the shared scenario.{Environment.NewLine}{diagnostics}");
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
            Transport = StimulationTransportKind.Conformance,
            MaxSetupTries = 1,
            TickIntervalMs = 1
        });

    private static async Task<IWssConformance> InitializeAsync(
        StimulationController controller,
        WssInitializationScenario scenario)
    {
        controller.Initialize();
        Assert.That(controller.TryGetConformance(out IWssConformance conformance), Is.True,
            "The C# implementation did not expose the emulator's Core conformance capability.");

        bool operationalStateObserved = false;
        bool streamObserved = false;
        for (int i = 0; i < InitializationPollLimit; i++)
        {
            operationalStateObserved = operationalStateObserved || controller.Started();
            streamObserved = streamObserved || conformance.StimulationHistory.Count > 0;
            if ((!scenario.RequiresOperationalState || operationalStateObserved) &&
                (!scenario.RequiresStreamObservation || streamObserved))
            {
                break;
            }

            await Task.Delay(1);
        }

        Assert.Multiple(() =>
        {
            if (scenario.RequiresOperationalState)
                Assert.That(operationalStateObserved, Is.True,
                    "Core did not complete initialization within the finite poll limit.");
            if (scenario.RequiresStreamObservation)
                Assert.That(streamObserved, Is.True,
                    "Core did not emit a startup stream within the finite poll limit.");
        });
        return conformance;
    }

    private static async Task<StimulationConformanceResult> WaitForStimulationAsync(
        IWssConformance conformance,
        WssStimulationBaseline baseline,
        WssStimulationExpectation expectation)
    {
        StimulationConformanceResult result = conformance.ValidateStimulation(expectation, baseline);
        for (int i = 0; i < OperationPollLimit && !result.Passed; i++)
        {
            await Task.Delay(1);
            result = conformance.ValidateStimulation(expectation, baseline);
        }

        return result;
    }

    private static string MapChannel(int channel) =>
        channel switch
        {
            1 => "thumb",
            2 => "index",
            3 => "middle",
            4 => "ring",
            5 => "pinky",
            _ => throw new ArgumentOutOfRangeException(nameof(channel), channel, "Unsupported wrapper channel.")
        };

    private static int MapTarget(byte target) =>
        target switch
        {
            (byte)WssTarget.Broadcast => 0,
            (byte)WssTarget.Wss1 => 1,
            (byte)WssTarget.Wss2 => 2,
            (byte)WssTarget.Wss3 => 3,
            _ => throw new ArgumentOutOfRangeException(nameof(target), target, "Unsupported wrapper target.")
        };

    private static int ToWrapperAmplitude(float amplitudeMa)
    {
        int amplitude = checked((int)amplitudeMa);
        Assert.That(amplitudeMa, Is.EqualTo(amplitude),
            "The C# implementation analog API requires a whole-number amplitude.");
        return amplitude;
    }

    private static bool IsStream(WssMessageObservation observation) =>
        observation.MessageId >= (byte)WSSMessageIDs.StreamChangeAll &&
        observation.MessageId <= (byte)WSSMessageIDs.StreamChangeNoPA;

    private static string BuildStopDiagnostics(
        IReadOnlyList<WssMessageObservation> history,
        WssMessageObservation? stop,
        long? stopCompletedSequence,
        bool finalStarted)
    {
        IEnumerable<WssMessageObservation> preStopStreams = history.Where(IsStream);
        if (stop != null)
            preStopStreams = preStopStreams.Where(item => item.SequenceNumber < stop.SequenceNumber);

        IEnumerable<WssMessageObservation> postCompletionStreams = stopCompletedSequence == null
            ? Array.Empty<WssMessageObservation>()
            : history.Where(item => item.SequenceNumber > stopCompletedSequence && IsStream(item));
        string[] lines = preStopStreams
            .TakeLast(2)
            .Select(item => $"pre-stop Stream: {FormatObservation(item)}")
            .Concat(new[]
            {
                stop == null ? "STOP: not observed" : $"STOP: {FormatObservation(stop)}",
                $"stopCompletedSequence: {stopCompletedSequence?.ToString(CultureInfo.InvariantCulture) ?? "not reached"}"
            })
            .Concat(postCompletionStreams.Select(item => $"post-completion Stream: {FormatObservation(item)}"))
            .Concat(new[] { $"final controller.Started(): {finalStarted}" })
            .ToArray();
        return string.Join(Environment.NewLine, lines);
    }

    private static string FormatObservation(WssMessageObservation observation) =>
        $"sequence={observation.SequenceNumber}, target=0x{observation.Target:X2}, " +
        $"messageId=0x{observation.MessageId:X2}, payload=" +
        string.Join(" ", observation.Payload.Select(value => value.ToString("X2", CultureInfo.InvariantCulture)));

    private static string CreateFixtureDirectory()
    {
        WssStimulationFixtureProfile fixture = WssBehaviorScenarios.StimulationFixture;
        string channel = WssBehaviorScenarios.DirectAnalog.Channel.ToString(CultureInfo.InvariantCulture);
        string directory = Path.Combine(Path.GetTempPath(), $"wss-csharp-implementation-conformance-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);

        var stimulationConfig = new
        {
            maxWSS = 1,
            firmware = "J03",
            broadcastTarget = "0x8F",
            wssTargets = new[] { "0x81", "0x82", "0x83" },
            useConfigAmpCurves = true,
            ampCurves = new[]
            {
                new
                {
                    LowThreshold = fixture.CurveLowThreshold,
                    LowConst = fixture.CurveLowConstant,
                    ExpPower = fixture.CurveExponent,
                    LinearOffset = fixture.CurveLinearOffset,
                    LinearSlope = fixture.CurveLinearSlope
                }
            }
        };
        var stimulationParameters = new
        {
            stim = new
            {
                ch = new Dictionary<string, object>
                {
                    [channel] = new
                    {
                        ampMode = fixture.AmplitudeMode,
                        minPW = fixture.MinimumPulseWidth,
                        maxPW = fixture.MaximumPulseWidth,
                        minPA = 0.0,
                        maxPA = 0.0,
                        defaultPA = fixture.DefaultAmplitudeMa,
                        defaultPW = 50,
                        IPI = fixture.InterPulseInterval
                    }
                }
            }
        };

        File.WriteAllText(
            Path.Combine(directory, "stimConfig.json"),
            JsonSerializer.Serialize(stimulationConfig));
        File.WriteAllText(
            Path.Combine(directory, "stimParams.json"),
            JsonSerializer.Serialize(stimulationParameters));
        return directory;
    }

    private static void DeleteFixtureDirectory(string directory)
    {
        if (Directory.Exists(directory))
            Directory.Delete(directory, recursive: true);
    }
}
