using System.Text.Json;
using NUnit.Framework;
using Wss.CoreModule;
using Wss.Testing;

namespace Wss.CSharpImplementation.Tests;

[TestFixture, NonParallelizable]
public sealed class ConfigurationReloadTests
{
    private string root = null!;
    private StimulationController controller = null!;

    [SetUp]
    public void SetUp()
    {
        root = Path.Combine(Path.GetTempPath(), "wss-host-reload-" + Guid.NewGuid().ToString("N"));
        WriteProfile(root, 1, 50, 150, 2, 1);
        controller = new StimulationController(new StimulationOptions
        { ConfigPath = root, Transport = StimulationTransportKind.Conformance, TickIntervalMs = 1 });
        controller.Initialize();
        Await(() => controller.Started());
    }

    [TearDown]
    public void TearDown()
    {
        controller.Dispose();
        Directory.Delete(root, true);
    }

    [Test]
    public void ReloadAppliesModelAndCalibrationWithoutReconnecting()
    {
        var original = Conformance();
        WriteProfile(root, 1, 100, 200, 4, .5);
        controller.LoadParamsJson();
        Assert.That(Conformance(), Is.SameAs(original));
        ObserveOutput(() => controller.StimWithMode("ch2", .5f), 125, 4);
        controller.UpdateChannelParams("ch2", 300, 100, 5);
        ObserveOutput(() => controller.StimulateNormalized("ch2", .5f), 200, 5);
        controller.LoadParamsJson();
        ObserveOutput(() => controller.StimulateNormalized("ch2", .5f), 200, 5);
    }

    [Test]
    public void ProfileFileAndDefaultReloadsPreserveStartupPathsAndStopRetiredStack()
    {
        var original = Conformance();
        ObserveOutput(() => controller.StimulateNormalized("ch2", .5f), 100, 2);
        string profile = Path.Combine(root, "profile with spaces");
        WriteProfile(profile, 2, 100, 200, 4, .5);
        controller.LoadParamsJson(profile);
        Await(() => controller.Started());
        Assert.That(controller.GetCoreConfigCTRL().MaxWss, Is.EqualTo(2));
        Assert.That(Conformance(), Is.Not.SameAs(original));
        Assert.That(original.StimulationHistory.Last(x => x.Channel == 2).PulseWidth, Is.Zero);
        Assert.That(original.StimulationHistory.Last(x => x.Channel == 2).PulseAmplitude, Is.Zero);
        long retiredCount = original.MessageHistory.Count;
        ObserveOutput(() => controller.StimWithMode("ch2", .5f), 125, 4);
        Assert.That(original.MessageHistory.Count, Is.EqualTo(retiredCount));

        string file = Path.Combine(profile, "specific parameters.json");
        File.Copy(Path.Combine(profile, "stimParams.json"), file);
        controller.LoadParamsJson(file);
        Await(() => controller.Started());
        Assert.That(controller.GetCoreConfigCTRL().MaxWss, Is.EqualTo(1));
        ObserveOutput(() => controller.StimWithMode("ch2", .5f), 150, 4);
        string old = Environment.CurrentDirectory;
        try
        {
            Environment.CurrentDirectory = profile;
            controller.LoadParamsJson();
            ObserveOutput(() => controller.StimWithMode("ch2", .5f), 100, 2);
        }
        finally { Environment.CurrentDirectory = old; }
    }

    [Test]
    public void CoreReloadUsesResetAndKeepsCurrentCalibration()
    {
        controller.UpdateChannelParams("ch2", 200, 100, 4);
        var original = Conformance();
        WriteCore(root, 2);
        controller.LoadCoreConfigFile();
        Await(() => controller.Started());
        Assert.That(Conformance(), Is.Not.SameAs(original));
        Assert.That(controller.GetCoreConfigCTRL().MaxWss, Is.EqualTo(2));
        ObserveOutput(() => controller.StimulateNormalized("ch2", .5f), 150, 4);
    }

    [Test]
    public void InvalidBundleLeavesTheWorkingConnectionAndValuesUntouched()
    {
        var original = Conformance();
        WriteCore(root, 2);
        File.WriteAllText(Path.Combine(root, "modelConfig.json"), "invalid");
        Assert.Throws<InvalidDataException>(() => controller.LoadParamsJson());
        Assert.That(Conformance(), Is.SameAs(original));
        Assert.That(controller.GetCoreConfigCTRL().MaxWss, Is.EqualTo(1));
        ObserveOutput(() => controller.StimWithMode("ch2", .5f), 100, 2);
    }

    [Test]
    public void UnpublishedTransportMustCleanUpBeforeSnapshotRetry()
    {
        controller.Shutdown();
        var snapshot = WssConfigurationSnapshot.ReadDefaults(root);
        var transport = new FailedConstructionTransport();
        // Fault injection at the host ownership boundary, without opening a device.
        const System.Reflection.BindingFlags flags = System.Reflection.BindingFlags.Instance | System.Reflection.BindingFlags.NonPublic;
        typeof(StimulationController).GetField("_pendingReload", flags)!.SetValue(controller, snapshot);
        typeof(StimulationController).GetField("_retiredTransport", flags)!.SetValue(controller, transport);
        File.WriteAllText(Path.Combine(root, "stimConfig.json"), "changed after staging");
        Assert.Throws<IOException>(() => controller.RetryReload());
        Assert.That(controller.Started(), Is.False);
        Assert.That(transport.Disposals, Is.EqualTo(1));
        controller.RetryReload();
        Await(() => controller.Started());
        Assert.That(transport.Disposals, Is.EqualTo(2));
        Assert.That(controller.LastReloadError, Is.Null);
        ObserveOutput(() => controller.StimWithMode("ch2", .5f), 100, 2);
    }

    private sealed class FailedConstructionTransport : Wss.Transports.ITransport
    {
        internal int Disposals;
        public bool IsConnected => false;
        public event Action<byte[]>? BytesReceived { add { } remove { } }
        public Task ConnectAsync(CancellationToken ct = default) => throw new NotSupportedException();
        public Task DisconnectAsync(CancellationToken ct = default) => Task.CompletedTask;
        public Task SendAsync(byte[] bytes, CancellationToken ct = default) => throw new NotSupportedException();
        public void Dispose()
        {
            if (++Disposals == 1) throw new IOException("Injected unpublished transport cleanup failure.");
        }
    }

    private IWssConformance Conformance()
    {
        Assert.That(controller.TryGetConformance(out var result), Is.True);
        return result;
    }

    private void ObserveOutput(Action operation, int pw, int amplitude)
    {
        var trace = Conformance();
        long baseline = trace.MessageHistory.Last().SequenceNumber;
        operation();
        Await(() => trace.StimulationHistory.Any(x => x.SequenceNumber > baseline && x.Channel == 2 &&
            x.PulseWidth == pw && x.PulseAmplitude == amplitude && x.InterPulseInterval == 13));
    }

    private static void Await(Func<bool> condition) =>
        Assert.That(SpinWait.SpinUntil(condition, 5000), Is.True, "Emulator did not observe the requested state/output.");

    private static void WriteProfile(string directory, int devices, int min, int max, int amplitude, double gain)
    {
        Directory.CreateDirectory(directory);
        WriteCore(directory, devices);
        var channels = Enumerable.Range(1, 9).ToDictionary(x => x.ToString(), _ => new
        { ampMode = "PW", minPW = min, maxPW = max, defaultPA = amplitude, IPI = 13 });
        File.WriteAllText(Path.Combine(directory, "stimParams.json"), JsonSerializer.Serialize(new { stim = new { ch = channels } }));
        File.WriteAllText(Path.Combine(directory, "modelConfig.json"), JsonSerializer.Serialize(new
        { calib = new { mode = "P" }, constants = new { PModeProportional = gain } }));
    }

    private static void WriteCore(string directory, int devices) => File.WriteAllText(Path.Combine(directory, "stimConfig.json"),
        JsonSerializer.Serialize(new
        {
            maxWSS = devices,
            firmware = "J03",
            useConfigAmpCurves = true,
            ampCurves = new[] { new { LowThreshold = 0, LowConst = 1, ExpPower = 1, LinearOffset = -1, LinearSlope = 1 } }
        }));
}
