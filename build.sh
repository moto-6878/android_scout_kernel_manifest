#!/bin/bash
KERNEL_ROOT_DIR=$PWD
TARGET_PRODUCT=scout
KERNEL_DEFCONFIG="mgk_64_k61_defconfig"
KERNEL_BUILD_VARIANT=user
KERNEL_TARGET_ARCH=arm64
KERNEL_DIR="kernel_device_modules-6.1"
LINUX_KERNEL_VERSION="kernel-6.1"
KERNEL_DEFCONFIG_OVERLAYS="mgk_64_k61_defconfig"
KERNEL_BAZEL_BUILD_OUT=out/target/product/${TARGET_PRODUCT}/obj/KLEAF_OBJ
KERNEL_BAZEL_DIST_OUT=out/target/product/${TARGET_PRODUCT}/obj/KLEAF_OBJ/dist

# Clear DIST_DIR to ensure a clean build
if [ -d "${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_DIST_OUT}" ]; then
    echo "Cleaning DIST_DIR: ${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_DIST_OUT}"
    rm -rf "${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_DIST_OUT:?}"/*
fi

# Disable Bzlmod as we are missing mgk_ext.bzl
if [ -f "MODULE.bazel" ]; then
    echo "Disabling MODULE.bazel (Bzlmod) as mgk_ext is missing..."
    mv MODULE.bazel MODULE.bazel.disabled
fi
if [ -f "WORKSPACE.bzlmod" ]; then
    rm -f WORKSPACE.bzlmod
fi

# Create WORKSPACE with legacy definitions
if [ ! -L "WORKSPACE" ] && [ ! -f "WORKSPACE" ]; then
    echo "Creating WORKSPACE..."
    cat > WORKSPACE << 'EOF'
load("//build/kernel/kleaf:workspace.bzl", "define_kleaf_workspace")
load("//build/bazel_mgk_rules:kleaf/key_value_repo.bzl", "key_value_repo")

key_value_repo(
    name = "mgk_info",
)

load("@mgk_info//:dict.bzl","KERNEL_VERSION")
define_kleaf_workspace(common_kernel_package = "@//"+KERNEL_VERSION)

load("//build/kernel/kleaf:workspace_epilog.bzl", "define_kleaf_workspace_epilog")
define_kleaf_workspace_epilog()

new_local_repository(
    name="mgk_internal",
    path="vendor/mediatek",
    build_file = "//build/bazel_mgk_rules:kleaf/BUILD.internal"
)

new_local_repository(
    name="mgk_ko",
    path="vendor/mediatek/kernel_modules",
    build_file = "//build/bazel_mgk_rules:kleaf/BUILD.ko"
)
EOF
fi

export BAZEL_DO_NOT_DETECT_CPP_TOOLCHAIN=1 DEFCONFIG_OVERLAYS="../../arch/arm64/configs/ext_config/moto-mgk_64_k61-scout.config" KERNEL_VERSION=kernel-6.1 SOURCE_DATE_EPOCH=0 JAVA_HOME="${KERNEL_ROOT_DIR}/prebuilts/jdk/jdk11/linux-x86" PATH="${KERNEL_ROOT_DIR}/prebuilts/jdk/jdk11/linux-x86/bin:${PATH}"

PRIVATE_BAZEL_BUILD_FLAG="--//build/bazel_mgk_rules:kernel_version=${LINUX_KERNEL_VERSION#kernel-} --experimental_writable_outputs --noenable_bzlmod --config=stamp --repo_manifest=${KERNEL_ROOT_DIR}/${KERNEL_DIR}/fake_manifest.xml"

my_kernel_target=${KERNEL_DEFCONFIG%_defconfig}

PRIVATE_BAZEL_BUILD_GOAL="//${KERNEL_DIR#kernel/}:${my_kernel_target}_customer_modules_install.${KERNEL_BUILD_VARIANT}"

PRIVATE_BAZEL_DIST_GOAL="//${KERNEL_DIR#kernel/}:${my_kernel_target}_customer_dist.${KERNEL_BUILD_VARIANT}"

# Run Bazel build
build/kernel/kleaf/bazel.sh --output_root=${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_BUILD_OUT} --output_base=${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_BUILD_OUT}/bazel/output_user_root/output_base build ${PRIVATE_BAZEL_BUILD_FLAG} ${PRIVATE_BAZEL_BUILD_GOAL}

build/kernel/kleaf/bazel.sh --output_root=${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_BUILD_OUT} --output_base=${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_BUILD_OUT}/bazel/output_user_root/output_base run ${PRIVATE_BAZEL_BUILD_FLAG} --nokmi_symbol_list_violations_check ${PRIVATE_BAZEL_DIST_GOAL} -- --dist_dir=${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_DIST_OUT}

build/kernel/kleaf/bazel.sh --output_root=${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_BUILD_OUT} --output_base=${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_BUILD_OUT}/bazel/output_user_root/output_base run ${PRIVATE_BAZEL_BUILD_FLAG} //${LINUX_KERNEL_VERSION}:kernel_aarch64_abi_dist -- --dist_dir=${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_DIST_OUT}/abi

# Copy Image.gz to DIST_DIR
# The kernel image is located deep in the dist directory structure by the Bazel build rules
IMAGE_GZ_SRC="${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_DIST_OUT}/${KERNEL_DIR}/mgk_64_k61_kernel_aarch64.user/Image.gz"
if [ -f "${IMAGE_GZ_SRC}" ]; then
    echo "Copying Image.gz to dist root..."
    cp "${IMAGE_GZ_SRC}" "${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_DIST_OUT}/"
else
    echo "Warning: Image.gz not found at ${IMAGE_GZ_SRC}"
fi

# Build DTBs for scout (mt6878) from device modules sources
echo "Building DTBs for ${TARGET_PRODUCT}..."
mkdir -p ${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_DIST_OUT}/dtbs

# Set up paths
DTS_DIR="${KERNEL_ROOT_DIR}/${KERNEL_DIR}/arch/${KERNEL_TARGET_ARCH}/boot/dts/mediatek"
CLANG="${KERNEL_ROOT_DIR}/prebuilts/clang/host/linux-x86/clang-r487747c/bin/clang"
DTC="${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_BUILD_OUT}/bazel/output_user_root/output_base/execroot/_main/bazel-out/k8-fastbuild/bin/${KERNEL_DIR}/mgk_64_k61.${KERNEL_BUILD_VARIANT}/scripts/dtc/dtc"

# Include paths for DTS preprocessing
# CRITICAL FIX: Device modules include path must come BEFORE kernel include path
# to pick up the correct header definitions (e.g. mtk-memory-port.h with MTK_M4U_PORT_ID macro)
DTC_INCLUDES="-I${KERNEL_ROOT_DIR}/${KERNEL_DIR}/include \
    -I${KERNEL_ROOT_DIR}/${LINUX_KERNEL_VERSION}/include \
    -I${KERNEL_ROOT_DIR}/${KERNEL_DIR}/arch/${KERNEL_TARGET_ARCH}/boot/dts \
    -I${DTS_DIR}"

# Check if DTC exists (use system dtc as fallback)
if [ ! -f "${DTC}" ]; then
    DTC=$(which dtc 2>/dev/null || echo "")
    if [ -z "${DTC}" ]; then
        echo "Warning: dtc not found, skipping DTB build"
        echo "Build complete! Outputs in: ${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_DIST_OUT}"
        exit 0
    fi
fi

# Build base DTB: mt6878.dtb
if [ -f "${DTS_DIR}/mt6878.dts" ]; then
    echo "  Building mt6878.dtb..."
    # Using -nostdinc to ensure we use only our explicit include paths in correct order
    ${CLANG} -E -nostdinc -undef -D__DTS__ -x assembler-with-cpp ${DTC_INCLUDES} \
        -o /tmp/mt6878.dts.preprocessed "${DTS_DIR}/mt6878.dts" && \
    ${DTC} -@ -I dts -O dtb -o "${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_DIST_OUT}/dtbs/mt6878.dtb" \
        /tmp/mt6878.dts.preprocessed && echo "    -> mt6878.dtb OK" || echo "    -> Failed"
fi

# Clean up temp files
rm -f /tmp/*.dts.preprocessed 2>/dev/null

# List built DTBs
echo ""
echo "DTBs built:"
ls -la ${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_DIST_OUT}/dtbs/*.dtb* 2>/dev/null || echo "  (none)"

# --- Module Organization ---
echo ""
echo "Organizing modules..."

DIST_DIR="${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_DIST_OUT}"

# Search paths
# System modules (GKI) are in the abi folder
SYSTEM_MODULES_SEARCH_PATH="${DIST_DIR}/abi"
# Vendor modules are in the device modules install directory
VENDOR_MODULES_SEARCH_PATH="${DIST_DIR}/kernel_device_modules-6.1/mgk_64_k61_customer_modules_install.user"
# Fallback path for vendor modules
VENDOR_MODULES_FALLBACK_PATH="${DIST_DIR}/kernel_device_modules-6.1/mgk_64_k61.user"

if [ -d "${VENDOR_MODULES_SEARCH_PATH}" ]; then
    echo "  System modules path: ${SYSTEM_MODULES_SEARCH_PATH}"
    echo "  Vendor modules path: ${VENDOR_MODULES_SEARCH_PATH}"
    echo "  Vendor fallback path: ${VENDOR_MODULES_FALLBACK_PATH}"
    
    # Define destination directories
    SYSTEM_MOD_DIR="${DIST_DIR}/system"
    VENDOR_MOD_DIR="${DIST_DIR}/vendor"
    VENDOR_RAMDISK_MOD_DIR="${DIST_DIR}/vendor_ramdisk"
    
    mkdir -p "${SYSTEM_MOD_DIR}" "${VENDOR_MOD_DIR}" "${VENDOR_RAMDISK_MOD_DIR}"
    
    # Helper function to copy modules from list
    copy_modules() {
        local list_file="$1"
        local dest_dir="$2"
        local label="$3"
        local search_path="$4"
        local fallback_path="$5"
        
        if [ -f "${list_file}" ]; then
            echo "  Processing ${label} from $(basename ${list_file})..."
            while IFS= read -r module || [ -n "$module" ]; do
                # Trim whitespace
                module=$(echo "$module" | xargs)
                [ -z "$module" ] && continue
                [ "${module:0:1}" = "#" ] && continue # Skip comments
                
                # Find module file (handle potential paths or just filename)
                local mod_name=$(basename "$module")
                # Find the module recursively in the search path
                # Use head -1 to pick the first match if duplicates exist (usually identical)
                local src_path=$(find "${search_path}" -name "${mod_name}" 2>/dev/null | head -1)
                
                if [ -z "${src_path}" ] && [ -n "${fallback_path}" ]; then
                     src_path=$(find "${fallback_path}" -name "${mod_name}" 2>/dev/null | head -1)
                     if [ -n "${src_path}" ]; then
                         echo "    Found in fallback: ${mod_name}"
                     fi
                fi

                if [ -n "${src_path}" ]; then
                    cp -f "${src_path}" "${dest_dir}/"
                else
                    echo "    Warning: Module ${mod_name} not found in ${search_path} (or fallback if provided)"
                fi
            done < "${list_file}"
            echo "    -> Copied to ${dest_dir}"
        else
            echo "  Skipping ${label}: List file not found: ${list_file}"
        fi
    }

    # 1. System Modules (No fallback)
    copy_modules "${KERNEL_ROOT_DIR}/build/manifest/modules.load.system" "${SYSTEM_MOD_DIR}" "System Modules" "${SYSTEM_MODULES_SEARCH_PATH}"
    
    # 2. Vendor Modules (With fallback)
    # Check for modules.load.vendor OR modules.recovery.vendor as user hinted variability
    if [ -f "${KERNEL_ROOT_DIR}/build/manifest/modules.load.vendor" ]; then
        copy_modules "${KERNEL_ROOT_DIR}/build/manifest/modules.load.vendor" "${VENDOR_MOD_DIR}" "Vendor Modules" "${VENDOR_MODULES_SEARCH_PATH}" "${VENDOR_MODULES_FALLBACK_PATH}"
    elif [ -f "${KERNEL_ROOT_DIR}/build/manifest/modules.recovery.vendor" ]; then
        copy_modules "${KERNEL_ROOT_DIR}/build/manifest/modules.recovery.vendor" "${VENDOR_MOD_DIR}" "Vendor Modules" "${VENDOR_MODULES_SEARCH_PATH}" "${VENDOR_MODULES_FALLBACK_PATH}"
    fi

    # 3. Vendor Ramdisk Modules (With fallback)
    if [ -f "${KERNEL_ROOT_DIR}/build/manifest/modules.load.vendor_ramdisk" ]; then
        copy_modules "${KERNEL_ROOT_DIR}/build/manifest/modules.load.vendor_ramdisk" "${VENDOR_RAMDISK_MOD_DIR}" "Vendor Ramdisk Modules" "${VENDOR_MODULES_SEARCH_PATH}" "${VENDOR_MODULES_FALLBACK_PATH}"
    fi
    # Recovery modules generally go to vendor_ramdisk in generic setups, or separate recovery ramdisk.
    # User requested: "recovery goes in vendor_ramdisk"
    if [ -f "${KERNEL_ROOT_DIR}/build/manifest/modules.load.recovery" ]; then
        copy_modules "${KERNEL_ROOT_DIR}/build/manifest/modules.load.recovery" "${VENDOR_RAMDISK_MOD_DIR}" "Recovery Modules (to vendor_ramdisk)" "${VENDOR_MODULES_SEARCH_PATH}" "${VENDOR_MODULES_FALLBACK_PATH}"
    fi

else
    echo "Warning: Could not find modules installation directory in dist: ${VENDOR_MODULES_SEARCH_PATH}"
fi

echo ""
echo "Build complete! Outputs in: ${KERNEL_ROOT_DIR}/${KERNEL_BAZEL_DIST_OUT}"
