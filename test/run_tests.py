#!/usr/bin/env python3
"""
Test runner - because manually testing is annoying

TODO: add more test cases
TODO: parallel execution?
"""

import subprocess
import sys
import os
from pathlib import Path
import time

def run_test(name, params):
    """Run a test and hope it works"""
    print(f"\n[{time.strftime('%H:%M:%S')}] Running: {name}")
    
    cmd = ["nextflow", "run", "main.nf", "-profile", "test,docker", "--outdir", f"test_results/{name}"]
    for k, v in params.items():
        cmd.extend([f"--{k}", str(v)])
    
    # add resume flag because tests fail randomly sometimes
    if os.path.exists(f"test_results/{name}"):
        cmd.append("-resume")
    
    result = subprocess.run(cmd, capture_output=True, text=True)
    
    if result.returncode != 0:
        print(f"STDERR: {result.stderr[-500:]}")  # last 500 chars
    
    return result.returncode == 0

def main():
    """Run all tests"""
    Path("test_results").mkdir(exist_ok=True)
    
    tests = {
        "basic": {"skip_markduplicates": "true"},
        "illumina_only": {"platform_filter": "illumina"},
        "rna_only": {"datatype_filter": "rna"}
    }
    
    passed = 0
    for name, params in tests.items():
        if run_test(name, params):
            print(f"[PASS] {name}")
            passed += 1
        else:
            print(f"[FAIL] {name}")
    
    print(f"\nSummary: {passed}/{len(tests)} tests passed")
    sys.exit(0 if passed == len(tests) else 1)

if __name__ == "__main__":
    main()
