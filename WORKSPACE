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
