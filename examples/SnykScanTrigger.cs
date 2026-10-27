// Minimal background-job client for the Snyk orchestrator pipeline (.NET 8+).
// Batches repos into runs of `maxTargetsPerRun` (default 5) and queues one pipeline run per batch.
// The same number is sent as the pipeline's `maxTargets` parameter so both sides agree.
using System.Net.Http.Headers;
using System.Net.Http.Json;
using System.Text;
using System.Text.Json;
using System.Text.Json.Serialization;

public sealed record ScanTarget(
    string RepoId,
    string Branch,                            // cloned at branch tip, e.g. "main" or "release/2026.10"
    string? Project = null,
    string? Key = null,                       // [A-Za-z0-9_]; defaults to repoId
    string[]? Technologies = null,            // null => [auto]
    string[]? ScanTypes = null,               // null => pipeline default
    ContainerImage[]? ContainerImages = null);

public sealed record ContainerImage(string Image, string? Dockerfile = null);

public sealed class SnykScanTrigger(HttpClient http, string org, string project, int pipelineId,
                                    int maxTargetsPerRun = 5)
{

    private static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    /// <param name="accessToken">PAT (basic) or Entra token for a service principal (bearer).</param>
    public static HttpClient CreateClient(string accessToken, bool isPat)
    {
        var client = new HttpClient();
        client.DefaultRequestHeaders.Authorization = isPat
            ? new AuthenticationHeaderValue("Basic", Convert.ToBase64String(Encoding.ASCII.GetBytes($":{accessToken}")))
            : new AuthenticationHeaderValue("Bearer", accessToken);
        return client;
    }

    public async Task<IReadOnlyList<int>> QueueAsync(IEnumerable<ScanTarget> targets, string requestId,
                                                     bool preview = false, CancellationToken ct = default)
    {
        ArgumentOutOfRangeException.ThrowIfLessThan(maxTargetsPerRun, 1);
        var runIds = new List<int>();
        var batchNo = 0;

        var list = targets.ToList();
        if (list.FirstOrDefault(t => string.IsNullOrWhiteSpace(t.RepoId) || string.IsNullOrWhiteSpace(t.Branch)) is { } bad)
            throw new ArgumentException($"repoId and branch are required (repo '{bad.RepoId}').");

        // Same repo twice in one run => duplicate stage names. Dedupe repo+branch,
        // and give a repo scanned on several branches an explicit stage key.
        var unique = list
            .DistinctBy(t => (t.RepoId.ToLowerInvariant(), t.Branch.ToLowerInvariant()))
            .GroupBy(t => t.RepoId.ToLowerInvariant())
            .SelectMany(g => g.Count() == 1
                ? g
                : g.Select((t, i) => t with { Key = t.Key ?? $"{t.RepoId.Replace('-', '_')}_{i + 1}" }));

        foreach (var batch in unique.Chunk(maxTargetsPerRun))
        {
            var body = new
            {
                previewRun = preview,
                templateParameters = new Dictionary<string, string>
                {
                    ["requestId"] = $"{requestId}-{++batchNo}",
                    ["maxTargets"] = maxTargetsPerRun.ToString(),
                    // Object parameters are passed as a JSON string.
                    ["scanTargets"] = JsonSerializer.Serialize(batch, Json)
                }
            };

            var url = $"https://dev.azure.com/{org}/{Uri.EscapeDataString(project)}/_apis/pipelines/{pipelineId}/runs?api-version=7.1";
            using var resp = await http.PostAsJsonAsync(url, body, ct);
            var payload = await resp.Content.ReadAsStringAsync(ct);
            if (!resp.IsSuccessStatusCode)
                throw new HttpRequestException($"Queue failed ({(int)resp.StatusCode}): {payload}");

            using var doc = JsonDocument.Parse(payload);
            if (doc.RootElement.TryGetProperty("id", out var id)) runIds.Add(id.GetInt32());
        }
        return runIds;
    }
}
