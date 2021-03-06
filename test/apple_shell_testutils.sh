#!/bin/bash

# Copyright 2017 The Bazel Authors. All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Common utilities that are useful across a variety of Apple shell integration
# tests.


# Usage: assert_exists <path>
#
# Asserts that the file at the given path exists.
function assert_exists() {
  path="$1"
  [ -f "$path" ] && return 0

  fail "Expected file '$path' to exist, but it did not"
  return 1
}


# Usage: assert_zip_contains <archive> <path_in_archive>
#
# Asserts that the file or directory at path `path_in_archive` exists in the
# zip `archive`.
function assert_zip_contains() {
  archive="$1"
  path="$2"

  # Build the regex we use to match by escaping a couple characters that might
  # appear in filenames, then surround it by ^ and $.
  path_regex="$(echo "$path" | sed -e 's/\([.+]\)/\\\1/g' -e 's/^.*$/^&$/g')"

  zip_contents=$(zipinfo -1 "$archive")
  echo "$zip_contents" | grep "$path_regex" > /dev/null \
      || fail "Archive $archive did not contain ${path};" \
              "contents were: $zip_contents"
}


# Usage: assert_zip_not_contains <archive> <path_in_archive>
#
# Asserts that the file or directory at path `path_in_archive` does not exist
# in the zip `archive`.
function assert_zip_not_contains() {
  archive="$1"
  path="$2"

  # Build the regex we use to match by escaping a couple characters that might
  # appear in filenames, then surround it by ^ and $.
  path_regex="$(echo "$path" | sed -e 's/\([.+]\)/\\\1/g' -e 's/^.*$/^&$/g')"

  zip_contents=$(zipinfo -1 "$archive")
  echo "$zip_contents" | grep "$path_regex" > /dev/null \
      && fail "Archive $archive contained $path, but it should not;" \
              "contents were: $zip_contents" \
      || true
}


# Usage: build_path <target_label>
#
# Returns the relative path to the BUILD file for the given target by stripping
# the leading slashes, then removing the target name portion (":foo") and
# appending "BUILD".
function build_path() {
  target_label="$1"
  no_slashes="${target_label#//}"
  echo "${no_slashes%%:*}/BUILD"
}


# Usage: create_dump_plist [--suffix SUFFIX] <ipa_label> <plist_path> <keys...>
#
# Concatenates a target named "dump_plist" to the BUILD file that owns
# `ipa_label`, which dumps keys and values from a plist into text files
# that can be checked using assertions.
#
# `--suffix SUFFIX` is optional, and if present, will be used as a suffix
# on the `dump_plist` rule name and will be used as a suffix on all the
# keypath file names dumped into. This allows multiple plists to be dumpe
# from a single target directory.
#
# `ipa_label` should be the absolute label of an IPA file generated by a
# bundling rule in the test client (for example, "//app:app.ipa").
#
# `plist_path` is the archive-root-relative path to the plist file to be
# dumped (for example, "Payload/app.app/Info.plist").
#
# The remaining arguments are keypaths in PlistBuddy notation representing
# the values to dump. Each value will be dumped to a file in the package's
# genfiles directory with the same name as the keypath, with colons in the
# keypath replaced by dots.
#
# Example:
#     create_dump_plist //app:app.ipa Payload/app.app/Info.plist \
#         CFBundleIdentifier CFBundleSupportedPlatforms:0
#     do_build ios //app:dump_plist
#     assert_equals "my.bundle.id" \
#         "$(cat "test-genfiles/app/CFBundleIdentifier")"
function create_dump_plist() {
  if [[ "$1" == "--suffix" ]]; then
    shift; SUFFIX="_$1"; shift
  else
    SUFFIX=
  fi
  ipa_label="$1"; shift
  plist_path="$1"; shift

  build_path="$(build_path "$ipa_label")"

  # There is no convenient way to get an arbitrary value out of a Plist file on
  # Linux, so we create an action we run on a Mac to dump out the values we
  # care about to files in a genrule, and then assert on the contents of those
  # files.
  cat >> "${build_path}" <<EOF
genrule(
    name = "dump_plist${SUFFIX}",
    srcs = ["${ipa_label}"],
    outs = [
EOF

  for keypath in "$@"; do
    filename="${keypath//:/.}${SUFFIX}"
    echo "        \"${filename}\"," >> "${build_path}"
  done

  cat >> "${build_path}" <<EOF
    ],
    cmd =
        "set -e && " +
        "temp=\$\$(mktemp -d \"\$\${TEST_TMPDIR:-/tmp}/dump_plist.XXXXXX\") && " +
        "/usr/bin/unzip -q \$(location ${ipa_label}) -d \$\${temp} && " +
        "plist=\$\${temp}/${plist_path} && " +
EOF

  for keypath in "$@"; do
    filename="${keypath//:/.}${SUFFIX}"
    echo "        \"/usr/libexec/PlistBuddy -c \\\"Print ${keypath}\\\" \$\${plist} > \$(@D)/${filename} && \" +" \
        >> "${build_path}"
  done

  cat >> "${build_path}" <<EOF
        "rm -rf \$\${temp}",
    tags = ["requires-darwin"],
)
EOF
}


# Usage: create_dump_codesign <ipa_label> <archive_path> <codesign_args...>
#
# Concatenates a target named "dump_codesign" to the BUILD file that owns
# `ipa_label`, which dumps the results of executing `codesign` with the given
# arguments on a path inside the archive. The results are sent to a file named
# `codesign_output` in the genfiles directory for the target's package.
#
# `ipa_label` should be the absolute label of an IPA file generated by a
# bundling rule in the test client (for example, "//app:app.ipa").
#
# `archive_path` should be the path within the archive on which codesign should
# be executed (for example, "Payload/app.app").
#
# `codesign_args` is a list of arguments that should be passed to the codesign
# invocation. They are inserted before the archive path.
function create_dump_codesign() {
  ipa_label="$1"; shift
  archive_path="$1"; shift

  build_path="$(build_path "$ipa_label")"

  cat >> "${build_path}" <<EOF
genrule(
    name = "dump_codesign",
    srcs = ["${ipa_label}"],
    outs = ["codesign_output"],
    cmd =
        "set -e && " +
        "temp=\$\$(mktemp -d \"\$\${TEST_TMPDIR:-/tmp}/dump_codesign.XXXXXX\") && " +
        "/usr/bin/unzip -q \$(location ${ipa_label}) -d \$\${temp} && " +
        "codesign $@ \$\${temp}/${archive_path} &> \$@ && " +
        "rm -rf \$\${temp}",
    tags = ["requires-darwin"],
)
EOF
}


# Usage: create_dump_codesign_count <ipa_label> <archive_paths...>
#
# Concatenates a target named "dump_codesign_count" to the BUILD file that owns
# `ipa_label`, which executes `codesign` on the files at the given archive
# paths and counts the number of unique certificates among them. The results
# are sent to a file named `codesign_count_output` in the genfiles directory
# for the target's package.
#
# This target works by passing all the files to a single invocation of
# `codesign` and dumping their requirements, removing the bundle identifier
# from each (since they will differ). This leaves only the static portions and
# the certificate information on each line, which can then be sorted and
# uniq'd, then finally the line count of the output is taken.
#
# This target can be used to verify that multiple files in an archive (such as
# the main executable and frameworks/dylibs) all have the same signature, by
# asserting that the output of this target is "1".
#
# `ipa_label` should be the absolute label of an IPA file generated by a
# bundling rule in the test client (for example, "//app:app.ipa").
#
# `archive_paths` should be a list of paths within the archive on which
# codesign should be executed (for example, "Payload/app.app/app").
function create_dump_codesign_count() {
  ipa_label="$1"; shift
  archive_paths=("$@")

  build_path="$(build_path "$ipa_label")"

  cat >> "${build_path}" <<EOF
genrule(
    name = "dump_codesign_count",
    srcs = ["${ipa_label}"],
    outs = ["codesign_count_output"],
    cmd =
        "set -e && " +
        "temp=\$\$(mktemp -d " +
        "\"\$\${TEST_TMPDIR:-/tmp}/dump_codesign_count.XXXXXX\") && " +
        "/usr/bin/unzip -q \$(location ${ipa_label}) -d \$\${temp} && " +
        "codesign -d -r- ${archive_paths[@]/#/\$\$temp/} 2>/dev/null | " +
        "sed -e 's/identifier \"[^\"]*\" //' | sort | uniq | " +
        "wc -l | tr -d ' ' > \$@ && " +
        "rm -rf \$\${temp}",
    tags = ["requires-darwin"],
)
EOF
}

# Usage: current_archs <platform>
#
# Prints the architectures for the given platform that were specified in the
# configuration used to run the current test. For multiple architectures, the
# values will be printed on separate lines; the output here is typically meant
# to be captured into an array.
function current_archs() {
  platform="$1"
  if [[ "$platform" == ios ]]; then
    # Fudge the ios platform name to match the expected command line option.
    platform=ios_multi
  fi

  for option in "${EXTRA_BUILD_OPTIONS[@]-}"; do
    case "$option" in
      --"${platform}"_cpus=*)
        value="$(echo "$option" | cut -d= -f2)"
        echo "$value" | tr "," "\n"
        return
        ;;
    esac
  done
}


# Usage: do_build <platform> <other options...>
#
# Helper function to invoke `bazel build` that applies --verbose_failures and
# log redirection for the test harness, along with any extra arguments that
# were passed in via the `apple_shell_test`'s `configurations` attribute.
# The first argument is the platform needed; the remaining arguments are passed
# directly to bazel.
#
# Test builds use "test-" as the output directory symlink prefix, so tests
# should expect to find their outputs in "test-bin" and "test-genfiles".
#
# Example:
#     do_build ios --some_other_flag //foo:bar
function do_build() {
  platform="$1"; shift

  declare -a bazel_options=("--symlink_prefix=test-" "--verbose_failures")

  declare -a sdk_options=("--xcode_version=$XCODE_VERSION_FOR_TESTS")
  if [ -n "${sdk_options[*]}" ]; then
    bazel_options+=("${sdk_options[@]}")
  else
    fail "Could not find a valid version of Xcode"
  fi

  if is_device_build "$platform"; then
    bazel_options+=("--ios_signing_cert_name=-")
  fi

  if [[ -n "${EXTRA_BUILD_OPTIONS[@]-}" ]]; then
    bazel_options+=( "${EXTRA_BUILD_OPTIONS[@]}" )
  fi

  bazel_options+=( \
      --define=bazel_rules_apple.mock_provisioning=true \
      --objccopt=-Werror --objccopt=-Wunused-command-line-argument \
      --objccopt=-Wno-unused-function --objccopt=-Wno-format \
      --objccopt=-Wno-unused-variable \
       "$@" \
  )

  echo "Executing: bazel build ${bazel_options[*]}" > "$TEST_log"
  bazel build "${bazel_options[@]}" > "$TEST_log" 2>&1
}


# Usage: is_ad_hoc_signed_build
#
# Returns a success code if the --ios_signing_cert_name flag is set to "-";
# otherwise, it returns a failure exit code.
function is_ad_hoc_signed_build() {
  for option in "${EXTRA_BUILD_OPTIONS[@]-}"; do
    if [[ "$option" == "--ios_signing_cert_name=-" ]]; then
      return 0
    fi
  done

  return 1
}


# Usage: is_bitcode_build
#
# Returns a success code if the --apple_bitcode flag is set to either
# "embedded" or "embedded_markers"; otherwise, it returns a failure exit code.
function is_bitcode_build() {
  for option in "${EXTRA_BUILD_OPTIONS[@]-}"; do
    case "$option" in
      --apple-bitcode=none)
        return 1
        ;;
      --apple_bitcode=*)
        return 0
        ;;
    esac
  done

  return 1
}


# Usage: is_device_build <platform>
#
# Returns a success exit code if the current architectures correspond to a
# device build, or a failure exit code if they correspond to a simulator build.
# Intended to let individual tests skip all or part of their logic when running
# under multiple configurations.
function is_device_build() {
  platform="$1"
  archs="$(current_archs "$platform")"

  # For simplicity, we just test the entire architecture list string and assume
  # users aren't writing tests with multiple incompatible architectures.
  [[ "$platform" == macos ]] || [[ "$archs" == arm* ]]
}


# Usage: print_debug_entitlements <binary_path>
#
# Extracts and prints the debug entitlements from the appropriate Mach-O
# section of the given binary.
function print_debug_entitlements() {
  binary="$1"

  # This monstrosity uses objdump to dump the hex content of the entitlements
  # section, strips off the leading addresses (and ignores lines that don't
  # look like hex), then runs it through `xxd` to turn the hex into ASCII.
  # The results should be the entitlements plist text, which we can compare
  # against.
  xcrun llvm-objdump -macho -section=__TEXT,__entitlements "$binary" | \
      sed -e 's/^[0-9a-f][0-9a-f]*[[:space:]][[:space:]]*//' \
          -e 'tx' -e 'd' -e ':x' | xxd -r -p
}


# Usage unzip_single_file <archive> <path_in_archive>
#
# Extracts and prints the contents of the file located at `path_in_archive`
# within the given zip `archive`.
function unzip_single_file() {
  archive="$1"
  path="$2"
  unzip -p "$archive" "$path"
}


# Usage: assert_binary_contains <archive> <path_in_archive> <symbol_string>
#
# Asserts that the binary at `path_in_archive` within the zip `archive`
# contains the string `symbol_string` in its objc runtime.
function assert_binary_contains() {
  archive="$1"
  path="$2"
  symbol_string="$3"

  mkdir -p tempdir
  fat_path="tempdir/fat_binary"
  thin_path="tempdir/thin_binary"

  unzip_single_file "$archive" "$path" > $fat_path
  declare -a archs=( $(current_archs "ios") )
  for arch in "${archs[@]}"; do
    assert_nm_contains "$arch" "$fat_path" "$symbol_string"
  done
  rm -rf tempdir
}


# Usage: assert_binary_not_contains <archive> <path_in_archive> <symbol_string>
#
# Asserts that the binary at `path_in_archive` within the zip `archive`
# does not contain the string `symbol_string` in its objc runtime.
function assert_binary_not_contains() {
  archive="$1"
  path="$2"
  symbol_string="$3"

  mkdir -p tempdir
  fat_path="tempdir/fat_binary"
  thin_path="tempdir/thin_binary"

  unzip_single_file "$archive" "$path" > $fat_path
  declare -a archs=( $(current_archs "ios") )
  for arch in "${archs[@]}"; do
    assert_nm_not_contains "$arch" "$fat_path" "$symbol_string"
  done
  rm -rf tempdir
}

# Usage: assert_nm_contains <arch> <path> <symbol_string>
#
# Uses nm and asserts that the binary at `path`
# contains the string `symbol_string` in its objc runtime.
function assert_nm_contains() {
  arch="$1"
  path="$2"
  symbol_string="$3"

  nm_contents=$(nm -defined-only -arch="$arch" "$fat_path")
  echo "$nm_contents" | grep "$symbol_string" >& /dev/null && return 0
  fail "Expected binary '$path' to contain '$symbol_string' but it did not"
}

# Usage: assert_nm_contains <arch> <path> <symbol_string>
#
# Uses nm and asserts that the binary at `path`
# does not contain the string `symbol_string` in its objc runtime.
function assert_nm_not_contains() {
  arch="$1"
  path="$2"
  symbol_string="$3"

  nm_contents=$(nm -defined-only -arch="$arch" "$fat_path")
  echo "$nm_contents" | grep "$symbol_string" >& /dev/null || return 0
  fail "Expected binary '$path' to not contain '$symbol_string' but it did"
}

# Usage: assert_contains_bitcode_maps <platform> <archive> <path_in_archive>
#
# Asserts that the IPA at `archive` contains bitcode symbol map of the binary
# at `path_in_archive` for each architecture being built for the `platform`.
function assert_ipa_contains_bitcode_maps() {
  platform="$1"
  archive="$2"
  binary="$3"

  assert_zip_contains "$archive" "$binary"
  unzip_single_file "$archive" "$binary" > $TEST_TMPDIR/tmp_bin
  declare -a archs=( $(current_archs "$platform") )
  for arch in "${archs[@]}"; do
    BIN_UUID=$(dwarfdump -u "$TEST_TMPDIR"/tmp_bin -arch "${arch}" | cut -d' ' -f2)
    assert_zip_contains "$archive" \
      "BCSymbolMaps/${BIN_UUID}.bcsymbolmap"
  done
}
