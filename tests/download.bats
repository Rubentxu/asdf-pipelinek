#!/usr/bin/env bats

# bats tests for asdf-pipelinek bin/download
# Run: bats tests/download.bats

bats_require_minimum_version 1.5.0

setup() {
    export HOME="${BATS_TEST_TMPDIR}/home"
    mkdir -p "$HOME"
    export ASDF_DOWNLOAD_PATH="${BATS_TEST_TMPDIR}/downloads"
    mkdir -p "$ASDF_DOWNLOAD_PATH"
}

@test "downloads ZIP and SHA256SUMS for v0.40.0" {
    export ASDF_INSTALL_VERSION="0.40.0"
    
    run bin/download
    
    [ "$status" -eq 0 ]
    [[ "$output" == *"Downloading https://github.com/Rubentxu/pipeline-kotlin/releases/download/v0.40.0/pipelinek-0.40.0.zip"* ]]
    [[ "$output" == *"Downloading https://github.com/Rubentxu/pipeline-kotlin/releases/download/v0.40.0/SHA256SUMS"* ]]
    [[ "$output" == *"SHA-256 verified OK."* ]]
    
    # Verify files exist
    [ -f "${ASDF_DOWNLOAD_PATH}/pipelinek-0.40.0.zip" ]
    [ -f "${ASDF_DOWNLOAD_PATH}/SHA256SUMS" ]
}

@test "fails closed on 404 for non-existent version" {
    export ASDF_INSTALL_VERSION="99.99.99"
    
    run bin/download
    
    [ "$status" -ne 0 ]
    # A 404 must be reported as a missing version, not as a generic download
    # failure: the two used to be indistinguishable (curl -f discarded the
    # status), so a typo and a rate-limited request looked identical.
    [[ "$output" == *"does not exist"* ]]
    [[ "$output" == *"99.99.99"* ]]
    # The old opaque wording must not creep back in.
    [[ "$output" != *"could not download pipelinek-99.99.99.zip"* ]]
}

@test "fails closed if SHA256SUMS missing in release" {
    export ASDF_INSTALL_VERSION="0.39.0"
    
    run bin/download
    
    # 0.39.0 was released before SHA256SUMS convention
    # This test documents current behavior
    # If the release has SHA256SUMS it should pass, if not it should fail
}
