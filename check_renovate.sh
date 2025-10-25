#!/bin/bash

echo "=================================="
echo "RENOVATE CONFIG ANALYSIS SCRIPT"
echo "=================================="
echo ""

# Check if we're in a git repository
if [ ! -d .git ]; then
    echo "ERROR: Not in a git repository root. Please run from repo root."
    exit 1
fi

OUTPUT_FILE="renovate_analysis_$(date +%Y%m%d_%H%M%S).txt"

{
    echo "REPOSITORY ANALYSIS FOR RENOVATE CONFIG"
    echo "Generated: $(date)"
    echo "=========================================="
    echo ""

    # 1. Repository structure
    echo "1. DIRECTORY STRUCTURE"
    echo "----------------------"
    tree -L 3 -I 'node_modules|.git|vendor' 2>/dev/null || find . -maxdepth 3 -type d | grep -v '\.git\|node_modules' | head -50
    echo ""

    # 2. Kubernetes files
    echo "2. KUBERNETES YAML FILES"
    echo "------------------------"
    find . -path "*/kubernetes/*.yaml" -o -path "*/kubernetes/*.yml" 2>/dev/null | head -20
    echo ""

    # 3. Helmfile files
    echo "3. HELMFILE CONFIGURATION"
    echo "-------------------------"
    find . -name "helmfile.yaml" -o -name "helmfile.yml" 2>/dev/null
    find . -path "*/helmfile.d/*.yaml" -o -path "*/helmfile.d/*.yml" 2>/dev/null | head -10
    echo ""

    # 4. Kustomization files
    echo "4. KUSTOMIZATION FILES"
    echo "----------------------"
    find . -name "kustomization.yaml" -o -name "kustomization.yml" 2>/dev/null
    echo ""

    # 5. GitHub Actions
    echo "5. GITHUB ACTIONS WORKFLOWS"
    echo "---------------------------"
    find .github/workflows -name "*.yml" -o -name "*.yaml" 2>/dev/null
    echo ""

    # 6. Docker references
    echo "6. DOCKER IMAGES (sample from files)"
    echo "-------------------------------------"
    grep -r "image:" . --include="*.yaml" --include="*.yml" 2>/dev/null | grep -v ".git" | head -15
    echo ""

    # 7. Helm charts references
    echo "7. HELM CHART REFERENCES"
    echo "------------------------"
    grep -r "chart:" . --include="*.yaml" --include="*.yml" 2>/dev/null | grep -v ".git" | head -15
    echo ""

    # 8. Mise/asdf tools
    echo "8. MISE/ASDF TOOL VERSIONS"
    echo "--------------------------"
    [ -f .mise.toml ] && echo "Found .mise.toml:" && cat .mise.toml
    [ -f .tool-versions ] && echo "Found .tool-versions:" && cat .tool-versions
    echo ""

    # 9. Environment files with renovate comments
    echo "9. FILES WITH RENOVATE ANNOTATIONS"
    echo "-----------------------------------"
    grep -r "# renovate:" . --include="*.yaml" --include="*.yml" --include="*.env" --include="*.sh" 2>/dev/null | grep -v ".git" | head -20
    echo ""

    # 10. Check for Flux
    echo "10. FLUX OPERATOR USAGE"
    echo "----------------------"
    grep -r "flux-operator\|flux-instance" . --include="*.yaml" --include="*.yml" 2>/dev/null | grep -v ".git" | head -10
    echo ""

    # 11. SOPS encrypted files
    echo "11. SOPS ENCRYPTED FILES"
    echo "------------------------"
    find . -name "*.sops.*" 2>/dev/null | head -10
    echo ""

    # 12. Sample Kubernetes manifest
    echo "12. SAMPLE KUBERNETES MANIFEST (first found)"
    echo "---------------------------------------------"
    SAMPLE_K8S=$(find . -path "*/kubernetes/*.yaml" 2>/dev/null | head -1)
    if [ -n "$SAMPLE_K8S" ]; then
        echo "File: $SAMPLE_K8S"
        echo "---"
        head -30 "$SAMPLE_K8S"
    fi
    echo ""

    # 13. Sample Helmfile
    echo "13. SAMPLE HELMFILE (if exists)"
    echo "-------------------------------"
    SAMPLE_HELMFILE=$(find . -name "helmfile.yaml" -o -name "helmfile.yml" 2>/dev/null | head -1)
    if [ -n "$SAMPLE_HELMFILE" ]; then
        echo "File: $SAMPLE_HELMFILE"
        echo "---"
        head -30 "$SAMPLE_HELMFILE"
    fi
    echo ""

    # 14. Package managers detected
    echo "14. DETECTED PACKAGE MANAGERS"
    echo "-----------------------------"
    [ -f package.json ] && echo "✓ npm/yarn (package.json found)"
    [ -f requirements.txt ] && echo "✓ pip (requirements.txt found)"
    [ -f go.mod ] && echo "✓ go modules (go.mod found)"
    [ -f Cargo.toml ] && echo "✓ cargo (Cargo.toml found)"
    [ -f Chart.yaml ] && echo "✓ helm chart (Chart.yaml found)"
    echo ""

    # 15. Current Renovate config
    echo "15. CURRENT RENOVATE CONFIGURATION"
    echo "-----------------------------------"
    if [ -f renovate.json5 ]; then
        echo "File: renovate.json5"
        cat renovate.json5
    elif [ -f renovate.json ]; then
        echo "File: renovate.json"
        cat renovate.json
    elif [ -f .github/renovate.json ]; then
        echo "File: .github/renovate.json"
        cat .github/renovate.json
    else
        echo "No renovate config found"
    fi
    echo ""

} > "$OUTPUT_FILE"

echo "✓ Analysis complete!"
echo "✓ Output saved to: $OUTPUT_FILE"
echo ""
echo "Please share this file with me for verification."
echo ""
echo "If the file is too large, you can also run specific sections:"
echo "  ./analyze_repo.sh | head -200    # First 200 lines"
echo "  cat $OUTPUT_FILE | grep -A 10 'KUBERNETES'  # Just Kubernetes section"
