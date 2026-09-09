#!/usr/bin/env python3
import os
import re
import json
import subprocess
from datetime import datetime

# Define standard search paths
CHORDE_GITOPS_DIR = "/home/bradyhau/workspace/SafeChord/Chorde/gitops"

def get_live_nodes_info():
    """Extract OS Kernel and K3s version dynamically via kubectl."""
    targets = []
    try:
        # Run kubectl to get node details in JSON format
        cmd = ["kubectl", "get", "nodes", "-o", "json"]
        result = subprocess.run(cmd, capture_output=True, text=True, check=True)
        data = json.loads(result.stdout)
        
        for item in data.get("items", []):
            node_name = item["metadata"]["name"]
            node_info = item.get("status", {}).get("nodeInfo", {})
            
            kernel_version = node_info.get("kernelVersion")
            kubelet_version = node_info.get("kubeletVersion") # K3s/K8s version
            os_image = node_info.get("osImage")
            
            if kernel_version:
                targets.append({
                    "name": "linux-kernel",
                    "version": kernel_version,
                    "type": "kernel",
                    "ecosystem": "Linux",
                    "source": f"live-node:{node_name} ({os_image})"
                })
            
            if kubelet_version:
                targets.append({
                    "name": "kubernetes",
                    "version": kubelet_version,
                    "type": "orchestrator",
                    "ecosystem": "Kubernetes",
                    "source": f"live-node:{node_name}"
                })
    except subprocess.CalledProcessError as e:
        print(f"Warning: kubectl command failed (is the cluster accessible?): {e.stderr.strip()}")
    except FileNotFoundError:
        print("Warning: kubectl CLI not found in PATH.")
    except Exception as e:
        print(f"Warning: Failed to fetch live node info via kubectl: {e}")
    
    return targets

def extract_images_from_yaml(directory):
    """Scan YAML files and extract container images using regex to handle templates."""
    targets = []
    # Regex to find 'image: <image_name>:<tag>'
    # Handles optional quotes and registries
    image_pattern = re.compile(r'image:\s*["\'\s]?([a-zA-Z0-9.\-_/]+):([a-zA-Z0-9.\-_]+)["\'\s]?')
    
    for root, _, files in os.walk(directory):
        for file in files:
            if file.endswith((".yaml", ".yml")):
                file_path = os.path.join(root, file)
                try:
                    with open(file_path, "r", encoding="utf-8") as f:
                        for line in f:
                            match = image_pattern.search(line)
                            if match:
                                image_name, image_tag = match.groups()
                                # Avoid duplicates within the same file source
                                exists = any(t["name"] == image_name and t["version"] == image_tag for t in targets)
                                if not exists:
                                    targets.append({
                                        "name": image_name,
                                        "version": image_tag,
                                        "type": "container-image",
                                        "ecosystem": "Docker",
                                        "source": f"file://{file_path.replace('/home/bradyhau/workspace/SafeChord', '')}"
                                    })
                except Exception as e:
                    print(f"Warning: Failed to read {file_path}: {e}")
    return targets

def main():
    print("Starting Infrastructure Target Extraction...")
    
    # 1. Gather dynamic runtime targets
    live_targets = get_live_nodes_info()
    
    # 2. Gather static GitOps manifest targets
    static_targets = extract_images_from_yaml(CHORDE_GITOPS_DIR)
    
    # Combined SBOM
    from datetime import timezone
    sbom = {
        "scan_time": datetime.now(timezone.utc).isoformat(),
        "targets": live_targets + static_targets
    }
    
    # Output file
    output_path = "/home/bradyhau/workspace/SafeChord/Chorde/scripts/infra_sbom_targets.json"
    os.makedirs(os.path.dirname(output_path), exist_ok=True)
    with open(output_path, "w", encoding="utf-8") as f:
        json.dump(sbom, f, indent=2)
        
    print(f"Successfully exported {len(sbom['targets'])} targets to {output_path}")

if __name__ == "__main__":
    main()
