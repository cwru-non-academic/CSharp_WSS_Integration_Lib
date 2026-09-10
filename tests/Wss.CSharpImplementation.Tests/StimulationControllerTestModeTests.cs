using System.Diagnostics;
using NUnit.Framework;

namespace Wss.CSharpImplementation.Tests;

[TestFixture]
public sealed class StimulationControllerTestModeTests
{
    [Test]
    public async Task TestModeInitializesAndShutsDownCleanly()
    {
        string directory = Path.Combine(Path.GetTempPath(), $"wss-test-mode-{Guid.NewGuid():N}");
        Directory.CreateDirectory(directory);
        StimulationController? controller = null;

        try
        {
            controller = new StimulationController(new StimulationOptions
            {
                ConfigPath = directory,
                Transport = StimulationTransportKind.Test,
                MaxSetupTries = 1,
                TickIntervalMs = 1
            });

            controller.Initialize();

            var timeout = Stopwatch.StartNew();
            while (!controller.Started() && timeout.Elapsed < TimeSpan.FromSeconds(5))
                await Task.Delay(10);

            Assert.Multiple(() =>
            {
                Assert.That(controller.Started(), Is.True,
                    "Test transport did not reach an operational state within the timeout.");
                Assert.That(controller.TryGetConformance(out _), Is.False,
                    "Test transport should not expose the conformance-only capability.");
            });

            controller.Shutdown();
            Assert.That(controller.Started(), Is.False);
        }
        finally
        {
            controller?.Dispose();
            if (Directory.Exists(directory))
                Directory.Delete(directory, recursive: true);
        }
    }
}
