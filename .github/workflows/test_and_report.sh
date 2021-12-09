#!/bin/sh
set -e -u

swift test --enable-code-coverage
swift demangle --compact <$(swift test --show-codecov-path) >test_coverage.json
python3 ${GITHUB_ACTION_PATH}/print_coverage_report.py
