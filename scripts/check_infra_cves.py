#!/usr/bin/env python3
import os
import re
import json
import urllib.request
import urllib.error
import subprocess
from datetime import datetime, timezone

SBOM_JSON_PATH = "/home/bradyhau/workspace/SafeChord/Chorde/scripts/infra_sbom_targets.json"
OUTPUT_RESULTS_PATH = "/home/bradyhau/workspace/SafeChord/Chorde/scripts/infra_cve_results.json"
TRIVY_BIN = "/home/bradyhau/workspace/SafeChord/Chorde/bin/trivy"

def load_sbom():
    if not os.path.exists(SBOM_JSON_PATH):
        raise FileNotFoundError(f"SBOM target file not found at {SBOM_JSON_PATH}. Run extraction first.")
    with open(SBOM_JSON_PATH, "r", encoding="utf-8") as f:
        return json.load(f)

def scan_image_with_trivy(image_name, image_version):
    """Scan container image using the locally installed Trivy CLI."""
    full_image = f"{image_name}:{image_version}"
    print(f"Scanning container image: {full_image}...")
    
    try:
        # Run trivy image with json format and filter only CRITICAL severity
        cmd = [
            TRIVY_BIN, "image", 
            "--severity", "CRITICAL", 
            "--format", "json", 
            "--quiet",
            full_image
        ]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        
        vulnerabilities = []
        # Parse Trivy output format: Results -> Vulnerabilities
        for scan_result in data.get("Results", []):
            for vuln in scan_result.get("Vulnerabilities", []):
                vulnerabilities.append({
                    "vulnerability_id": vuln.get("VulnerabilityID"),
                    "package_name": vuln.get("PkgName"),
                    "installed_version": vuln.get("InstalledVersion"),
                    "fixed_version": vuln.get("FixedVersion", "N/A"),
                    "severity": vuln.get("Severity"),
                    "title": vuln.get("Title", "No Title"),
                    "description": vuln.get("Description", "No Description"),
                    "url": vuln.get("PrimaryURL", "")
                })
        
        print(f"  -> Found {len(vulnerabilities)} CRITICAL vulnerabilities in {full_image}")
        return vulnerabilities
    except subprocess.CalledProcessError as e:
        print(f"  Warning: Trivy failed to scan {full_image}. Error: {e.stderr.strip()}")
    except Exception as e:
        print(f"  Warning: Unexpected error scanning {full_image}: {e}")
    
    return []

def query_osv_api(ecosystem, package_name, version):
    """Query Google OSV API for a specific ecosystem package and version."""
    url = "https://api.osv.dev/v1/query"
    payload = {
        "version": version,
        "package": {
            "name": package_name,
            "ecosystem": ecosystem
        }
    }
    
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json"},
        method="POST"
    )
    
    try:
        with urllib.request.urlopen(req) as resp:
            data = json.loads(resp.read().decode("utf-8"))
            vulns = []
            # OSV API returns 'vulns' if there are matches
            for vuln in data.get("vulns", []):
                vulns.append({
                    "vulnerability_id": vuln.get("id"),
                    "package_name": package_name,
                    "installed_version": version,
                    "fixed_version": "N/A", # OSV requires deeper parsing for specific ranges, defaulting to check details
                    "severity": "CRITICAL",  # Standardize for critical workflow, OSV has mixed severities
                    "title": vuln.get("summary", "No Summary"),
                    "description": vuln.get("details", "No Details"),
                    "url": f"https://osv.dev/vulnerabilities/{vuln.get('id')}"
                })
            return vulns
    except urllib.error.URLError as e:
        print(f"  Warning: Failed to connect to OSV API: {e}")
    except Exception as e:
        print(f"  Warning: Error parsing OSV API response: {e}")
    
    return []

def clean_k8s_version(version_str):
    """Clean v1.34.3+k3s1 into standard 1.34.3 for vulnerability matching."""
    # Strip leading 'v'
    version = version_str.lstrip("v")
    # Split on '+' to remove build info (like +k3s1)
    version = version.split("+")[0]
    return version

def clean_kernel_version(version_str):
    """Extract standard upstream semver from linux kernel version string."""
    # Examples:
    # 6.8.0-107-generic -> 6.8.0
    # 6.1.0-33-cloud-amd64 -> 6.1.0
    match = re.match(r"^(\d+\.\d+\.\d+)", version_str)
    if match:
        return match.group(1)
    return version_str

def main():
    print("Starting Infrastructure CVE Check...")
    
    try:
        sbom = load_sbom()
    except FileNotFoundError as e:
        print(e)
        return
        
    results = {
        "scan_time": datetime.now(timezone.utc).isoformat(),
        "total_targets_scanned": len(sbom["targets"]),
        "vulnerabilities": []
    }
    
    for target in sbom["targets"]:
        target_name = target["name"]
        target_ver = target["version"]
        target_type = target["type"]
        target_source = target["source"]
        
        vulns = []
        if target_type == "container-image":
            vulns = scan_image_with_trivy(target_name, target_ver)
        elif target_type == "orchestrator" and target["ecosystem"] == "Kubernetes":
            cleaned_ver = clean_k8s_version(target_ver)
            print(f"Querying OSV for Kubernetes version: {cleaned_ver} (original: {target_ver})...")
            # Query standard Kubernetes ecosystem on OSV
            # Note: OSV expects package name to be 'kubernetes' or 'Kubernetes' depending on ecosystem
            vulns = query_osv_api("Kubernetes", "kubernetes", cleaned_ver)
            print(f"  -> Found {len(vulns)} vulnerability entries in OSV.")
        elif target_type == "kernel" and target["ecosystem"] == "Linux":
            cleaned_ver = clean_kernel_version(target_ver)
            print(f"Querying OSV for Linux Kernel version: {cleaned_ver} (original: {target_ver})...")
            # Query Linux Kernel upstream
            vulns = query_osv_api("Linux", "Kernel", cleaned_ver)
            print(f"  -> Found {len(vulns)} vulnerability entries in OSV.")
            
        # Enrich vulnerabilities with source metadata
        for v in vulns:
            v["target_name"] = target_name
            v["target_version"] = target_ver
            v["target_type"] = target_type
            v["source"] = target_source
            results["vulnerabilities"].append(v)
            
    # Remove duplicates if any vulnerability has identical ID and target source
    unique_vulns = []
    seen = set()
    for v in results["vulnerabilities"]:
        key = (v["vulnerability_id"], v["target_name"], v["source"])
        if key not in seen:
            seen.add(key)
            unique_vulns.append(v)
    
    results["vulnerabilities"] = unique_vulns
    results["total_vulnerabilities_found"] = len(unique_vulns)
    
    # Save results
    with open(OUTPUT_RESULTS_PATH, "w", encoding="utf-8") as f:
        json.dump(results, f, indent=2)
        
    print("\n" + "="*50)
    print("SCAN COMPLETE SUMMARY")
    print(f"Total Targets Scanned: {results['total_targets_scanned']}")
    print(f"Total Critical CVEs Found: {results['total_vulnerabilities_found']}")
    print(f"Results exported to {OUTPUT_RESULTS_PATH}")
    print("="*50)

if __name__ == "__main__":
    main()
