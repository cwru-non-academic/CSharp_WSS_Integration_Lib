# Final producer contract: tools/ArtifactBuild/manifests/universal.json.
$WssUniversalFiles = @(
    'WSS_Core_Interface.dll', 'WSS.Transport.Serial.dll', 'WSS.Transport.BLE.dll',
    'Newtonsoft.Json.dll', 'System.IO.Ports.dll', 'System.Memory.dll', 'System.Buffers.dll',
    'System.Numerics.Vectors.dll', 'System.Runtime.CompilerServices.Unsafe.dll',
    'System.Security.Permissions.dll', 'System.Security.AccessControl.dll', 'System.Security.Principal.Windows.dll',
    'backends/windows/WSS.Transport.BLE.Windows.dll',
    'backends/windows/WSS.Transport.BLE.Windows.Native.dll', 'backends/windows/WssBleWindows.dll',
    'backends/linux/WSS.Transport.BLE.Linux.dll', 'backends/linux/Linux.Bluetooth.dll', 'backends/linux/Tmds.DBus.dll',
    'backends/linux/Microsoft.Bcl.AsyncInterfaces.dll', 'backends/linux/System.Reflection.Emit.dll',
    'backends/linux/System.Reflection.Emit.ILGeneration.dll', 'backends/linux/System.Threading.Tasks.Extensions.dll',
    'runtimes/win/lib/net8.0/System.IO.Ports.dll', 'runtimes/unix/lib/net8.0/System.IO.Ports.dll',
    'runtimes/linux-x64/native/libSystem.IO.Ports.Native.so'
)
