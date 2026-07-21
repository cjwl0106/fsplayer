#! /usr/bin/env bash
#
# Copyright (C) 2024 Matt Reach<qianlongxu@gmail.com>

# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

THIS_DIR=$(DIRNAME=$(dirname "$0"); cd "$DIRNAME"; pwd)
cd "$THIS_DIR"

set -e

FMN="FSPlayer"

function get_inputs_with_path()
{
    fmwk="${1}/$FMN.framework"
    inputs=""
    if [[ -d $fmwk ]]; then
        inputs="$inputs -framework $fmwk"
    fi
    # dSYM 不包含在 xcframework 中，避免在其他项目中出现
    # "Missing path from XCFramework as defined by DebugSymbolsPath" 错误。
    # 如果需要调试符号，请在项目中单独配置 dSYM 搜索路径。
    echo "$inputs"
}

function get_inputs()
{
    # add macOS
    macos_inputs=$(get_inputs_with_path 'macos/Release')
    # add iOS
    ios_inputs=$(get_inputs_with_path 'ios/Release-iphoneos')
    # add iOS Simulator
    ios_sim_inputs=$(get_inputs_with_path 'ios/Release-iphonesimulator')
    # add tvOS
    tvos_inputs=$(get_inputs_with_path 'tvos/Release-appletvos')
    # add tvOS Simulator
    tvos_sim_inputs=$(get_inputs_with_path 'tvos/Release-appletvsimulator')
    
    echo "${macos_inputs} ${ios_inputs} ${ios_sim_inputs} ${tvos_inputs} ${tvos_sim_inputs}"
}

function do_make_xcframework() {
    cd ..
    local XC_XCFRMK_DIR='xcframewrok'
    inputs="$(get_inputs)"
    output=$XC_XCFRMK_DIR/${FMN}.xcframework
    rm -rf "$output"
    # echo "xcodebuild -create-xcframework $inputs -output $output"
    xcodebuild -create-xcframework $inputs -output $output
}

do_make_xcframework