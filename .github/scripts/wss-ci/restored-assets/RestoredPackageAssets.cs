using System;
using System.IO;
using System.Linq;
using System.Text.Json;

namespace Wss.BuildTools
{
    // Canonical owner: WSSCore tools/ArtifactBuild. Distributed by sync-tooling.mjs.
    // Reads restore metadata only. Never loads package assemblies or evaluates a project.
    public static class RestoredPackageAssets
    {
        public static string Resolve(JsonElement assets, string package, string asset)
        {
            RequireRelative(asset, "asset");
            var library = ObjectProperty(ObjectProperty(assets, "libraries"), package);
            if (StringProperty(library, "type") != "package")
                throw new InvalidDataException("Restored library is not a package: " + package);
            var files = library.GetProperty("files");
            if (files.ValueKind != JsonValueKind.Array ||
                !files.EnumerateArray().Any(file => file.ValueKind == JsonValueKind.String && file.GetString() == asset))
                throw new InvalidDataException("Asset is not declared by restored package " + package + ": " + asset);
            var packagePath = StringProperty(library, "path");
            RequireRelative(packagePath, "package path");
            if (!string.Equals(packagePath, package.ToLowerInvariant(), StringComparison.Ordinal))
                throw new InvalidDataException("Restored package path differs from exact package/version: " + package);
            var folders = ObjectProperty(assets, "packageFolders");
            var searched = new System.Collections.Generic.List<string>();
            foreach (var folder in folders.EnumerateObject())
            {
                if (!Path.IsPathFullyQualified(folder.Name))
                    throw new InvalidDataException("Restored package folder must be absolute: " + folder.Name);
                var path = Path.GetFullPath(Path.Combine(folder.Name, packagePath, asset));
                searched.Add(path);
                if (File.Exists(path)) return path;
            }
            throw new FileNotFoundException("Restored package asset was not found: " + package + "/" + asset +
                ". Searched declared packageFolders: " + string.Join("; ", searched));
        }

        public static string ResolveProjectAsset(string assetsFile, string projectPath, string package, string asset, string framework)
        {
            var assetsPath = Path.GetFullPath(assetsFile);
            var project = Path.GetFullPath(projectPath);
            if (!File.Exists(project)) throw new FileNotFoundException("Expected restored project is missing.", project);
            if (!File.Exists(assetsPath)) throw new FileNotFoundException("Explicit project.assets.json is missing; restore the actual build project.", assetsPath);
            if (File.GetLastWriteTimeUtc(assetsPath) < File.GetLastWriteTimeUtc(project))
                throw new InvalidDataException("Project assets are stale: " + assetsPath + " predates " + project);
            try
            {
                using (var document = JsonDocument.Parse(File.ReadAllText(assetsPath)))
                {
                    var root = document.RootElement;
                    AssertUniqueProperties(root);
                    var restore = ObjectProperty(ObjectProperty(root, "project"), "restore");
                    var recordedProject = StringProperty(restore, "projectPath");
                    var comparison = OperatingSystem.IsWindows() ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;
                    if (!Path.IsPathFullyQualified(recordedProject) || !string.Equals(Path.GetFullPath(recordedProject), project, comparison))
                        throw new InvalidDataException("Project assets belong to a different project: " + recordedProject + "; expected " + project);
                    var targets = ObjectProperty(root, "targets");
                    var matching = targets.EnumerateObject().Where(target => target.Name == framework || target.Name.StartsWith(framework + "/", StringComparison.Ordinal)).ToArray();
                    if (matching.Length == 0)
                        throw new InvalidDataException("Restored target is missing: " + framework);
                    foreach (var target in matching)
                    {
                        var entry = ObjectProperty(target.Value, package);
                        if (StringProperty(entry, "type") != "package")
                            throw new InvalidDataException("Target library is not the required package: " + package);
                    }
                    return Resolve(root, package, asset);
                }
            }
            catch (Exception exception) when (exception is JsonException || exception is System.Collections.Generic.KeyNotFoundException || exception is InvalidOperationException)
            {
                throw new InvalidDataException("Malformed or incomplete restored assets " + assetsPath + ": " + exception.Message, exception);
            }
        }

        private static JsonElement ObjectProperty(JsonElement parent, string name)
        {
            if (parent.ValueKind != JsonValueKind.Object || !parent.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.Object)
                throw new InvalidDataException("Restored assets require object property: " + name);
            return value;
        }

        private static string StringProperty(JsonElement parent, string name)
        {
            if (parent.ValueKind != JsonValueKind.Object || !parent.TryGetProperty(name, out var value) || value.ValueKind != JsonValueKind.String || string.IsNullOrWhiteSpace(value.GetString()))
                throw new InvalidDataException("Restored assets require nonempty string property: " + name);
            return value.GetString()!;
        }

        private static void RequireRelative(string path, string label)
        {
            if (string.IsNullOrWhiteSpace(path) || Path.IsPathRooted(path) || path.Contains('\\') || path.Contains(':') ||
                path.Split('/').Any(part => part.Length == 0 || part == "." || part == ".."))
                throw new InvalidDataException("Restored " + label + " must remain inside its package: " + path);
        }

        private static void AssertUniqueProperties(JsonElement value)
        {
            if (value.ValueKind == JsonValueKind.Object)
            {
                var names = new System.Collections.Generic.HashSet<string>(StringComparer.Ordinal);
                foreach (var property in value.EnumerateObject())
                {
                    if (!names.Add(property.Name)) throw new InvalidDataException("Duplicate restored-assets property: " + property.Name);
                    AssertUniqueProperties(property.Value);
                }
            }
            else if (value.ValueKind == JsonValueKind.Array)
                foreach (var item in value.EnumerateArray()) AssertUniqueProperties(item);
        }
    }
}
