using System;
using System.IO;
using System.Linq;
using System.Security.Cryptography;
using System.Text.Json;

namespace Wss.BuildTools
{
    // Parent-process-only proof. No setters, public constructor or serialized child input.
    public sealed class RestoredAssetProof
    {
        public string ProjectPath { get; }
        public string AssetsPath { get; }
        public string ProjectSha256 { get; }
        public string AssetsSha256 { get; }
        public string Package { get; }
        public string Asset { get; }
        public string Framework { get; }
        public string PackageDirectory { get; }
        public string NeutralAssetPath { get; }
        public string NeutralSha256 { get; }

        internal RestoredAssetProof(string project, string assets, string projectHash, string assetsHash,
            string package, string asset, string framework, string directory, string path, string hash)
        {
            ProjectPath = project; AssetsPath = assets; ProjectSha256 = projectHash; AssetsSha256 = assetsHash;
            Package = package; Asset = asset; Framework = framework; PackageDirectory = directory;
            NeutralAssetPath = path; NeutralSha256 = hash;
        }
    }

    // Canonical owner: WSSCore tools/ArtifactBuild. Distributed by sync-tooling.mjs.
    // Reads restore metadata only. Never loads package assemblies or evaluates a project.
    public static class RestoredPackageAssets
    {
        private static StringComparison PathComparison => OperatingSystem.IsWindows()
            ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

        public static string Resolve(JsonElement assets, string package, string asset)
        {
            return ResolveWithIdentity(assets, package, asset).AssetPath;
        }

        private static (string PackageDirectory, string AssetPath) ResolveWithIdentity(JsonElement assets, string package, string asset)
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
            // NuGet's package selection is package-wide, not the first folder containing
            // this particular asset. SDK 9 ResolvePackageAssets recognizes either the
            // extraction-completion metadata or the legacy package SHA512 marker.
            // Marker presence selects the root even if an individual asset is missing.
            var hashFileName = packagePath.Replace('/', '.') + ".nupkg.sha512";
            foreach (var folder in folders.EnumerateObject())
            {
                if (!Path.IsPathFullyQualified(folder.Name))
                    throw new InvalidDataException("Restored package folder must be absolute: " + folder.Name);
                var directory = Path.GetFullPath(Path.Combine(folder.Name, packagePath));
                searched.Add(directory);
                if (!File.Exists(Path.Combine(directory, ".nupkg.metadata")) &&
                    !File.Exists(Path.Combine(directory, hashFileName))) continue;
                var path = Path.GetFullPath(Path.Combine(directory, asset));
                if (!File.Exists(path))
                    throw new FileNotFoundException("Asset is missing from the NuGet-selected package directory; fallback is forbidden: " + directory + "; asset: " + asset, path);
                return (directory, path);
            }
            throw new FileNotFoundException("Restored package was not found with a NuGet extraction marker: " + package +
                ". Searched declared packageFolders: " + string.Join("; ", searched));
        }

        public static string ResolveProjectAsset(string assetsFile, string projectPath, string package, string asset, string framework)
        {
            var assetsPath = Path.GetFullPath(assetsFile);
            var project = Path.GetFullPath(projectPath);
            ValidateFiles(assetsPath, project);
            return ResolveProject(File.ReadAllBytes(assetsPath), assetsPath, project, package, asset, framework).AssetPath;
        }

        public static RestoredAssetProof CaptureProjectAsset(string assetsFile, string projectPath, string package, string asset, string framework)
        {
            var assetsPath = Path.GetFullPath(assetsFile);
            var project = Path.GetFullPath(projectPath);
            ValidateFiles(assetsPath, project);
            var projectHash = HashRegularFile(project);
            var assetsBytes = ReadRegularFile(assetsPath);
            var assetsHash = Hash(assetsBytes);
            var selected = ResolveProject(assetsBytes, assetsPath, project, package, asset, framework);
            var neutralHash = HashRegularFile(selected.AssetPath);
            // Capture cannot silently mix metadata/project versions during concurrent changes.
            if (projectHash != HashRegularFile(project) || assetsHash != HashRegularFile(assetsPath))
                throw new InvalidDataException("Restored proof inputs changed during capture.");
            return new RestoredAssetProof(project, assetsPath, projectHash, assetsHash, package, asset,
                framework, selected.PackageDirectory, selected.AssetPath, neutralHash);
        }

        public static void AssertProjectAssetProof(RestoredAssetProof proof, string assetsFile, string projectPath,
            string package, string asset, string framework)
        {
            if (proof == null) throw new InvalidDataException("A parent-captured restored asset proof is required.");
            if (!string.Equals(proof.ProjectPath, Path.GetFullPath(projectPath), PathComparison) ||
                !string.Equals(proof.AssetsPath, Path.GetFullPath(assetsFile), PathComparison) ||
                proof.Package != package || proof.Asset != asset || proof.Framework != framework)
                throw new InvalidDataException("Restored proof belongs to a different project, assets file or package contract.");
            // Reject changed metadata before resolving any child-supplied package location.
            if (HashRegularFile(proof.ProjectPath) != proof.ProjectSha256 || HashRegularFile(proof.AssetsPath) != proof.AssetsSha256)
                throw new InvalidDataException("Selected code changed restored proof project/assets content.");
            var current = CaptureProjectAsset(assetsFile, projectPath, package, asset, framework);
            if (current.ProjectSha256 != proof.ProjectSha256 || current.AssetsSha256 != proof.AssetsSha256)
                throw new InvalidDataException("Selected code changed restored proof project/assets content.");
            if (!string.Equals(current.PackageDirectory, proof.PackageDirectory, PathComparison) ||
                !string.Equals(current.NeutralAssetPath, proof.NeutralAssetPath, PathComparison))
                throw new InvalidDataException("Selected code changed restored package/asset resolution identity.");
            if (current.NeutralSha256 != proof.NeutralSha256)
                throw new InvalidDataException("Selected code changed restored neutral asset bytes.");
        }

        private static void ValidateFiles(string assetsPath, string project)
        {
            if (!File.Exists(project)) throw new FileNotFoundException("Expected restored project is missing.", project);
            if (!File.Exists(assetsPath)) throw new FileNotFoundException("Explicit project.assets.json is missing; restore the actual build project.", assetsPath);
            if (File.GetLastWriteTimeUtc(assetsPath) < File.GetLastWriteTimeUtc(project))
                throw new InvalidDataException("Project assets are stale: " + assetsPath + " predates " + project);
        }

        private static (string PackageDirectory, string AssetPath) ResolveProject(byte[] bytes, string assetsPath,
            string project, string package, string asset, string framework)
        {
            try
            {
                using (var document = JsonDocument.Parse(bytes))
                {
                    var root = document.RootElement;
                    AssertUniqueProperties(root);
                    var restore = ObjectProperty(ObjectProperty(root, "project"), "restore");
                    var recordedProject = StringProperty(restore, "projectPath");
                    if (!Path.IsPathFullyQualified(recordedProject) || !string.Equals(Path.GetFullPath(recordedProject), project, PathComparison))
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
                    // The neutral file is an explicit package-declared alternative allowed
                    // by the output policy. It need not be the RID-selected runtime copy.
                    return ResolveWithIdentity(root, package, asset);
                }
            }
            catch (Exception exception) when (exception is JsonException || exception is System.Collections.Generic.KeyNotFoundException || exception is InvalidOperationException)
            {
                throw new InvalidDataException("Malformed or incomplete restored assets " + assetsPath + ": " + exception.Message, exception);
            }
        }

        private static byte[] ReadRegularFile(string path)
        {
            var current = Path.GetFullPath(path);
            while (!string.IsNullOrEmpty(current))
            {
                if ((File.GetAttributes(current) & FileAttributes.ReparsePoint) != 0)
                    throw new InvalidDataException("Restored proof contains a redirected/reparse path: " + current);
                var parent = Path.GetDirectoryName(current);
                if (parent == current) break;
                current = parent ?? string.Empty;
            }
            return File.ReadAllBytes(path);
        }

        private static string Hash(byte[] bytes) => Convert.ToHexString(SHA256.HashData(bytes));
        private static string HashRegularFile(string path) => Hash(ReadRegularFile(path));

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