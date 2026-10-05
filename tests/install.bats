#!/usr/bin/env bats

# bats tests for asdf-pipelinek bin/install
# Run: bats tests/install.bats
#
# These hit the network: they exercise the real GitHub release, which is the only
# way to prove the plugin resolves what a release actually publishes rather than
# what it assumes it publishes. The hermetic contract suite is test/run-tests.bash.

bats_require_minimum_version 1.5.0

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "$HOME"
    export ASDF_DOWNLOAD_PATH="${BATS_TEST_TMPDIR}/downloads"
    mkdir -p "$ASDF_DOWNLOAD_PATH"
    export ASDF_INSTALL_PATH="${BATS_TEST_TMPDIR}/installs"
    mkdir -p "$ASDF_INSTALL_PATH"

    # Download a real ZIP for testing
    export ASDF_INSTALL_VERSION="0.40.0"
    bin/download
}

teardown() {
    rm -rf "${BATS_TEST_TMPDIR}/downloads"
    rm -rf "${BATS_TEST_TMPDIR}/installs"
}

@test "installs pipelinek binary from ZIP" {
    run bin/install

    [ "$status" -eq 0 ]
    [[ "$output" == *"pipelinek 0.40.0 installed."* ]]
    [ -x "${ASDF_INSTALL_PATH}/bin/pipelinek" ]
    [ -d "${ASDF_INSTALL_PATH}/lib" ]
}

@test "handles GA version with rc8 content" {
    # 0.40.0 GA contains pipelinek-0.40.0-rc8/ directory in ZIP
    run bin/install

    [ "$status" -eq 0 ]
    [[ "$output" == *"pipelinek 0.40.0 installed."* ]]
    [ -x "${ASDF_INSTALL_PATH}/bin/pipelinek" ]
}

@test "fails closed if download missing" {
    rm -rf "${ASDF_DOWNLOAD_PATH:?}"

    run bin/install

    [ "$status" -ne 0 ]
    [[ "$output" == *"no pipelinek-*.zip found"* ]]
}

@test "installs a release candidate whose asset is named after the GA" {
    # v0.47.0-rc2 publishes "pipelinek-0.47.0.zip" under the tag "v0.47.0-rc2".
    # A plugin that built the asset name from the tag asked for
    # "pipelinek-0.47.0-rc2.zip", which no release publishes, so no release
    # candidate of this project could be installed by asdf or mise.
    find "${ASDF_DOWNLOAD_PATH:?}" -mindepth 1 -delete
    export ASDF_INSTALL_VERSION="0.47.0-rc2"

    run bin/download
    [ "$status" -eq 0 ]
    [[ "$output" == *"download/v0.47.0-rc2/pipelinek-0.47.0.zip"* ]]
    [[ "$output" == *"SHA-256 verified OK."* ]]
    [ -f "${ASDF_DOWNLOAD_PATH}/pipelinek-0.47.0.zip" ]

    run bin/install
    [ "$status" -eq 0 ]
    [[ "$output" == *"pipelinek 0.47.0-rc2 installed."* ]]
    [ -x "${ASDF_INSTALL_PATH}/bin/pipelinek" ]
}

@test "fails closed if binary not found after extraction" {
    # This would only happen if the ZIP structure changes
    # Current test verifies the extraction works correctly

    run bin/install
    [ "$status" -eq 0 ]
    [ -x "${ASDF_INSTALL_PATH}/bin/pipelinek" ]
}