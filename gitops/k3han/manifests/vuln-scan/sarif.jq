# Per-image trivy SARIF -> one SARIF run for Code Scanning (slurped input).
# Input: an array of
#   {"ref", "image", "doc": <trivy SARIF>}       an image trivy analysed
#   {"ref", "image", "uncovered": <reason>}       an image it could not
#
# Alert identity (operations page §3.1, Chorde#40): one alert is one CVE in one
# package of one image repository. The rule is the CVE ID; the location is
# <image repo>/<package>, with no registry, tag, digest or version. trivy's own
# location is the image repo for OS packages and the file inside the image for
# language packages, which for Python carries the package and Python versions,
# so an upgrade would otherwise close the alert and open a "new" one.
# Two tags of one repository share an alert; each result lists where it was seen.

# "ghcr.io/dexidp/dex@sha256:..." -> "dexidp/dex"; "docker.io/library/redis:7" -> "library/redis"
def repo:
  sub("@.*$"; "")
  | sub(":[^/]*$"; "")
  | split("/")
  | if length > 1 and (.[0] | test("[.:]") or . == "localhost") then .[1:] else . end
  | join("/");

# trivy writes the package as the first "Package: " line of a result's message.
def package:
  [.message.text | split("\n")[] | select(startswith("Package: ")) | ltrimstr("Package: ")]
  | first // "unknown-package";

def location($uri):
  [{physicalLocation: {artifactLocation: {uri: $uri},
                       region: {startLine: 1, startColumn: 1, endLine: 1, endColumn: 1}}}];

def not_covered_rule: {
  id: "vuln-scan/not-covered",
  name: "NotCovered",
  shortDescription: {text: "Image not covered by the vulnerability scan"},
  fullDescription: {text: "trivy could not analyse this image, or found no OS and no package in it. No finding for this image is not evidence that it is clean."},
  defaultConfiguration: {level: "warning"},
  help: {
    text: "The scanner could not analyse this image. Its absence of findings means nothing. Check the reason in the alert and the scan log.",
    markdown: "The scanner could not analyse this image. Its absence of findings means nothing. Check the reason in the alert and the scan log."
  },
  properties: {tags: ["security", "not-covered"], precision: "very-high"}
};

. as $entries
| ([$entries[] | select(.doc) | .doc.runs[0].tool.driver] | first // {}) as $driver
| [ $entries[]
    | select(.doc)
    | .image as $image | .ref as $ref | (.ref | repo) as $repo
    | .doc.runs[].results[]
    | { ruleId, level,
        uri: ($repo + "/" + package),
        text: .message.text,
        seen: "\($image) (\($ref)): \(.locations[0].physicalLocation.artifactLocation.uri // "?")" }
  ]
| group_by([.ruleId, .uri])
| map({ ruleId: .[0].ruleId,
        level: .[0].level,
        message: {text: (.[0].text + "\n\nSeen at:\n" + (map("- " + .seen) | unique | join("\n")))},
        locations: location(.[0].uri) }) as $findings
| [ $entries[]
    | select(.uncovered)
    | {uri: (.ref | repo), seen: "\(.image) (\(.ref)): \(.uncovered)"} ]
| group_by(.uri)
| map({ ruleId: "vuln-scan/not-covered",
        level: "warning",
        message: {text: ("Not covered: no finding for this image means nothing.\n" + (map("- " + .seen) | unique | join("\n")))},
        locations: location(.[0].uri) }) as $uncovered
| {
    "$schema": "https://json.schemastore.org/sarif-2.1.0.json",
    version: "2.1.0",
    runs: [{
      tool: {driver: {
        name: "Trivy",
        fullName: ($driver.fullName // "Trivy Vulnerability Scanner"),
        version: ($driver.version // "unknown"),
        informationUri: "https://github.com/aquasecurity/trivy",
        rules: (([$entries[] | select(.doc) | .doc.runs[].tool.driver.rules[]] | unique_by(.id) | map(del(.ruleIndex))) + [not_covered_rule])
      }},
      automationDetails: {id: "vuln-scan/"},
      results: ($findings + $uncovered)
    }]
  }
