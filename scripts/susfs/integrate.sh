#!/usr/bin/env bash
# KernelSU-Next v3.4.2 + SUSFS v2.3.0 integration (hand-authored)
# Driver side: graft susfs CMD dispatch into KSUN's existing reboot kprobe.
# Kernel side: apply susfs fs-side (50_) minus the conflicting setresuid hunk.
set -euo pipefail

KSUN_DIR="${1:?KSUN dir}"      # KernelSU-Next checkout (v3.4.2)
S4K_DIR="${2:?susfs4ksu dir}"  # susfs4ksu gki-android14-6.1 (v2.3.0)
KROOT="${3:?kernel root}"      # the peridot kernel tree

P10="$S4K_DIR/kernel_patches/KernelSU/10_enable_susfs_for_ksu.patch"
P50="$S4K_DIR/kernel_patches/50_add_susfs_in_gki-android14-6.1.patch"

echo "[*] === DRIVER SIDE (KSUN) ==="

# --- 1) Kconfig: append the susfs menu (extracted verbatim from upstream 10_) ---
python3 - "$P10" "$KSUN_DIR/kernel/Kconfig" <<'PY'
import sys, re
patch, kconfig = sys.argv[1], sys.argv[2]
src = open(patch, encoding="utf-8", errors="replace").read()
# grab the Kconfig file hunk, keep only added lines (strip leading '+')
m = re.search(r'diff --git a/kernel/Kconfig.*?(?=\ndiff --git )', src, re.S)
block = m.group(0)
added = []
for ln in block.splitlines():
    if ln.startswith('+') and not ln.startswith('+++'):
        added.append(ln[1:])
menu = "\n".join(added)
assert 'config KSU_SUSFS' in menu and menu.strip().endswith('endmenu'), "Kconfig extract failed"
# upstream bug: some stanzas have help text with no `help` keyword -> Kconfig parse error.
# Insert `help` before the first help-text line of any stanza that lacks it.
fixed, seen_help, in_stanza = [], False, False
for ln in menu.splitlines():
    s = ln.strip()
    if s.startswith('config ') or s.startswith('menu') or s == 'endmenu':
        seen_help, in_stanza = False, s.startswith('config ')
    elif s == 'help':
        seen_help = True
    elif in_stanza and s.startswith('- ') and not seen_help:
        fixed.append('\thelp')      # inject the missing keyword
        seen_help = True
    fixed.append(ln)
menu = "\n".join(fixed)
with open(kconfig, 'a', encoding='utf-8') as f:
    f.write("\n" + menu + "\n")
print("  [+] appended KSU_SUSFS menu to kernel/Kconfig (%d lines)" % len(added))
PY

# --- 2) supercall.c: add include + graft susfs dispatch into reboot kprobe ---
python3 - "$P10" "$KSUN_DIR/kernel/supercall/supercall.c" <<'PY'
import sys, re
patch, sc = sys.argv[1], sys.argv[2]
src = open(patch, encoding="utf-8", errors="replace").read()
code = open(sc, encoding="utf-8").read()

# reconstruct the added (dispatch.c) code by stripping '+' from added lines
m = re.search(r'diff --git a/kernel/supercall/dispatch\.c.*?(?=\ndiff --git )', src, re.S)
added = "\n".join(ln[1:] for ln in m.group(0).splitlines()
                   if ln.startswith('+') and not ln.startswith('+++'))
# pull the case-list between 'switch(cmd) {' and the closing brace of the switch
sm = re.search(r'switch\(cmd\) \{\n(.*?\n)\s*\}\n\s*\}', added, re.S)
sw = sm.group(1).rstrip('\n')
# upstream returns -EINVAL on default which is illegal from a kprobe pre_handler; make it 0
sw = re.sub(r'default:\s*\n\s*return -EINVAL;', 'default:\n                return 0;', sw)
assert 'CMD_SUSFS_ADD_SUS_PATH' in sw and 'susfs_show_version' in sw, "switch extract failed"

disp = (
    "\n#ifdef CONFIG_KSU_SUSFS\n"
    "    /* susfs command dispatch (grafted into KSUN's reboot kprobe) */\n"
    "    if (magic2 == SUSFS_MAGIC && current_uid().val == 0) {\n"
    "        void __user *susfs_uptr = (void __user *)arg4;\n"
    "        void __user **arg = &susfs_uptr;\n"
    "        /* kernelsu_init() resolved these pre-policy, where they can only come back\n"
    "         * as SECINITSID_KERNEL; this path is post-policy, so retry once. */\n"
    "        { extern u32 susfs_ksu_sid; extern void susfs_ksu_resolve_sids(void);\n"
    "          if (unlikely(!susfs_ksu_sid)) susfs_ksu_resolve_sids(); }\n"
    "        switch(cmd) {\n" + sw + "\n"
    "        }\n"
    "    }\n"
    "#endif // CONFIG_KSU_SUSFS\n"
)

# add include after the utsname include
inc = '#include <linux/utsname.h> // utsname() and uts_sem\n'
assert inc in code
# cred.h + sched.h MUST precede susfs.h: susfs_def.h's inline helpers use
# current_uid()/current, which are otherwise undeclared at this include point.
code = code.replace(inc, inc + "#ifdef CONFIG_KSU_SUSFS\n#include <linux/cred.h>\n#include <linux/sched.h>\n#include <linux/susfs.h>\n#endif\n", 1)

# insert dispatch right after the arg extraction line in reboot_handler_pre
anchor = "    unsigned long reply = (unsigned long)arg4;\n"
assert anchor in code, "reboot_handler_pre anchor not found"
code = code.replace(anchor, anchor + disp, 1)

open(sc, 'w', encoding='utf-8').write(code)
print("  [+] grafted susfs dispatch + include into supercall.c")
PY

# --- 2b) selinux.c: define susfs_is_current_ksu_domain() ---
# The fs-side (fs/namespace.c, fs/proc_namespace.c) externs this but defines it
# nowhere. Raw-KSU defines it in its driver via a bespoke susfs_ksu_sid. KSUN
# v3.4.2 already caches the ksu-domain SID, so we just delegate to is_ksu_domain().
python3 - "$KSUN_DIR/kernel/selinux/selinux.c" <<'PY'
import sys
f = sys.argv[1]
code = open(f, encoding="utf-8").read()
assert 'bool is_ksu_domain(' in code, "KSUN is_ksu_domain() not found — API changed"
assert 'security_secctx_to_secid(' in code, "KSUN security_secctx_to_secid usage not found"
# fs-side needs: susfs_is_current_ksu_domain() [namespace.c] and the u32 SID globals
# susfs_ksu_sid/susfs_priv_app_sid [avc.c denial-log spoofing]. Port raw-KSU's idea:
# define the globals and resolve them via security_secctx_to_secid at init.
glue = ("\n#ifdef CONFIG_KSU_SUSFS\n"
        "#include <linux/jump_label.h>  /* DEFINE_STATIC_KEY_TRUE */\n"
        "#include <linux/namei.h>       /* struct filename */\n"
        "/* --- susfs glue (hand-port) --- */\n"
        "u32 susfs_ksu_sid __read_mostly = 0;      /* consumed by security/selinux/avc.c */\n"
        "u32 susfs_priv_app_sid __read_mostly = 0;  /* consumed by security/selinux/avc.c */\n"
        "\n"
        "/* fs-side (namespace.c) domain check: reuse KSUN's cached-SID detection. */\n"
        "bool susfs_is_current_ksu_domain(void)\n{\n"
        "\treturn is_ksu_domain();\n}\n"
        "\n"
        "/* Resolve the SIDs susfs's avc.c hook compares against.\n"
        " *\n"
        " * security_secctx_to_secid() yields SECINITSID_KERNEL (1) -- NOT 0 -- when it runs\n"
        " * before the SELinux policy is loaded, and kernelsu_init() runs long before it.\n"
        " * A bare call there therefore pins both SIDs to 1 for the life of the boot: real\n"
        " * ksu-domain denials never match (so they leak into the audit log) and kernel-domain\n"
        " * ones get mislabelled as priv_app. Only latch a SID once policy is actually up\n"
        " * (sid > SECINITSID_KERNEL); leaving it 0 keeps the avc spoof inert and lets the\n"
        " * supercall path -- which only runs post-policy -- retry and get the real value. */\n"
        "void susfs_ksu_resolve_sids(void)\n{\n"
        "\tu32 sid = 0;\n"
        "\n"
        "\tif (!security_secctx_to_secid(KERNEL_SU_CONTEXT, strlen(KERNEL_SU_CONTEXT), &sid) &&\n"
        "\t    sid > 1 /* SECINITSID_KERNEL */)\n"
        "\t\tsusfs_ksu_sid = sid;\n"
        "\tsid = 0;\n"
        "\tif (!security_secctx_to_secid(\"u:r:priv_app:s0:c512,c768\",\n"
        "\t\t\t\t      strlen(\"u:r:priv_app:s0:c512,c768\"), &sid) &&\n"
        "\t    sid > 1)\n"
        "\t\tsusfs_priv_app_sid = sid;\n"
        "\tpr_info(\"susfs: ksu_sid=%u priv_app_sid=%u\\n\", susfs_ksu_sid, susfs_priv_app_sid);\n"
        "}\n"
        "\n"
        "/* Vestigial weishu manual-hook shims. susfs's 50_ patch adds these inline\n"
         " * su-hooks in fs/{stat,exec,open}.c; KSUN v3.4.2 keeps its own hook paths, so they\n"
        " * are no-ops here (return 0 = 'not handled, proceed'). susfs's OWN enforcement\n"
        " * (susfs_sus_kstat_spoof_*, sus_path/mount) is separate and unaffected. */\n"
         "/* WEAK: the 50_ fs patch declares these exact filename-based hooks. A\n"
         " * strong copy would become a duplicate if a future KSUN sucompat tree\n"
         " * provides one, so keep every compatibility shim weak. */\n"
         "int __attribute__((weak)) ksu_handle_stat(int *dfd, struct filename **filename, int *flags) { return 0; }\n"
         "void __attribute__((weak)) ksu_handle_vfs_fstat(int fd, void *kstat_size_ptr) { }\n"
         "int __attribute__((weak)) ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags) { return 0; }\n"
         "int __attribute__((weak)) ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags) { return 0; }\n"
         "int __attribute__((weak)) ksu_handle_faccessat(int *dfd, struct filename **filename, int *mode, int *flags) { return 0; }\n"
         "int __attribute__((weak)) ksu_handle_post_execveat_sucompat(int *fd, struct filename **filename_ptr, void *argv, void *envp, int *flags, int *retval) { return 0; }\n"
        "\n"
        "/* Inert weishu selinux-hide + init_rc symbols referenced by susfs's 50_ patch\n"
         " * (security/selinux/hooks.c, fs/stat.c). KSUN v3.4.2 has its OWN selinux-hide\n"
        " * (feature/selinux_hide.c, static symbols), so keep the weishu path dormant:\n"
        " * running=false -> hooks.c takes the normal selinux path; the init_rc key just\n"
        " * gates the no-op ksu_handle_vfs_fstat stub. KSUN's static copies don't clash. */\n"
        "bool ksu_selinux_hide_running __read_mostly;\n"
        "struct selinux_state fake_state;\n"
        "DEFINE_STATIC_KEY_TRUE(ksu_is_init_rc_hook_enabled);\n"
        "#endif // CONFIG_KSU_SUSFS\n")
if 'susfs_is_current_ksu_domain' not in code:
    code = code.rstrip('\n') + '\n' + glue
open(f, 'w', encoding='utf-8').write(code)
print("  [+] defined susfs_is_current_ksu_domain + SID globals + resolver in selinux.c")
PY

# --- 3) init.c: call susfs_init() before supercalls_init() ---
python3 - "$KSUN_DIR/kernel/core/init.c" <<'PY'
import sys
f = sys.argv[1]
code = open(f, encoding="utf-8").read()
# Do NOT include susfs.h here: it pulls in susfs_def.h whose inline helpers use
# current_uid()/current, which aren't declared this early in init.c -> build error.
# We only need susfs_init(); extern-declare it (and the resolver) locally.
anchor = "\tksu_supercalls_init();"
assert anchor in code, "supercalls_init anchor not found"
code = code.replace(anchor,
    "#ifdef CONFIG_KSU_SUSFS\n"
    "\t{ extern void susfs_init(void); susfs_init(); }\n"
    "\t{ extern void susfs_ksu_resolve_sids(void); susfs_ksu_resolve_sids(); }\n"
    "#endif\n" + anchor, 1)
open(f, 'w', encoding='utf-8').write(code)
print("  [+] added susfs_init() + susfs_ksu_resolve_sids() calls in kernelsu_init")
PY

echo "[*] === KERNEL SIDE (peridot) ==="

# --- 4) copy susfs fs-side sources + headers ---
cp -v "$S4K_DIR"/kernel_patches/fs/*.c "$KROOT/fs/"
cp -v "$S4K_DIR"/kernel_patches/include/linux/*.h "$KROOT/include/linux/"

# --- 5) apply 50_ MINUS the conflicting kernel/sys.c setresuid hunk ---
python3 - "$P50" "$KROOT/susfs50.trimmed.patch" <<'PY'
import sys, re
src = open(sys.argv[1], encoding="utf-8", errors="replace").read()
out = []
# Files whose 50_ hunk is PURELY weishu-KSU infrastructure (0 susfs content) and
# which the current KSUN tree either implements itself (selinux-hide) or doesn't use
# (kprobe mode, not manual input/init_rc/read hooks). Verified: grep susfs_ == 0.
DROP_WHOLE = ('a/kernel/reboot.c',            # calls ksu_handle_sys_reboot (kprobe handles it)
              'a/security/selinux/selinuxfs.c',# weishu selinux-hide; KSUN has its own
              'a/drivers/input/input.c',        # weishu input hook
              'a/fs/read_write.c')              # weishu sys_read + init_rc hook
for chunk in re.split(r'(?=^diff --git )', src, flags=re.M):
    dropped = next((f for f in DROP_WHOLE if chunk.startswith('diff --git ' + f)), None)
    if dropped:
        print("  [+] dropped %s hunk (weishu-only, 0 susfs content)" % dropped)
        continue
    # within kernel/sys.c drop only the 3-arg setresuid hunk (conflicts w/ KSUN's 2-arg)
    if chunk.startswith('diff --git a/kernel/sys.c'):
        hunks = re.split(r'(?=^@@ )', chunk, flags=re.M)
        kept = [hunks[0]]
        for h in hunks[1:]:
            if 'ksu_handle_setresuid' in h:
                continue
            kept.append(h)
        chunk = ''.join(kept)
    out.append(chunk)
open(sys.argv[2], 'w', encoding='utf-8').write(''.join(out))
print("  [+] wrote 50_ (weishu-only hunks + setresuid hunk removed)")
PY

cd "$KROOT"
# namespace.c's top decl hunk is expected to reject (handled by the fixup below);
# don't let set -e abort on patch's exit 1.
patch -p1 < susfs50.trimmed.patch || true
# The ONLY reject we accept is namespace.c's top-of-file decl hunk (the fixup below
# re-creates it). Any other reject -- in namespace.c or elsewhere -- means the base
# moved under the susfs patch; that must fail loudly, not be deleted and compiled.
if [ -f fs/namespace.c.rej ]; then
  _hunks=$(grep -c '^@@' fs/namespace.c.rej || true)
  if [ "$_hunks" != 1 ] || ! grep -q '^@@ -32,10 ' fs/namespace.c.rej; then
    echo "[!] fs/namespace.c: unexpected reject(s) -- not just the known top-decl hunk:"; cat fs/namespace.c.rej; exit 1
  fi
fi
_other=$(find . -path ./out -prune -o -name '*.rej' -print | grep -v '^./fs/namespace.c.rej$' || true)
if [ -n "$_other" ]; then echo "[!] rejects outside namespace.c:"; for r in $_other; do echo "== $r =="; cat "$r"; done; exit 1; fi
rm -f susfs50.trimmed.patch

# --- 6) namespace.c decl fixup (the one expected reject) ---
python3 - <<'PY'
f="fs/namespace.c"; s=open(f).read()
assert "#include <linux/mnt_idmapping.h>\n" in s, "namespace.c anchor <linux/mnt_idmapping.h> missing"
assert '#include "internal.h"\n' in s, 'namespace.c anchor "internal.h" missing'
inc="#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n#include <linux/susfs_def.h>\n#endif\n"
ext=("#ifdef CONFIG_KSU_SUSFS_SUS_MOUNT\n"
     "extern bool susfs_is_current_ksu_domain(void);\n"
     "extern struct static_key_true susfs_is_sdcard_android_data_not_decrypted;\n"
     "#define CL_COPY_MNT_NS BIT(25)\n#endif\n")
if "susfs_def.h" not in s:
    s=s.replace("#include <linux/mnt_idmapping.h>\n","#include <linux/mnt_idmapping.h>\n"+inc,1)
if "extern bool susfs_is_current_ksu_domain" not in s:
    s=s.replace('#include "internal.h"\n','#include "internal.h"\n'+ext,1)
open(f,"w").write(s)
print("  [+] namespace.c susfs decls applied")
PY
rm -f fs/namespace.c.rej fs/namespace.c.orig   # only the known hunk-1 reject survives the gate above
# patch(1) leaves .orig copies for every file whose hunks applied; they are
# useful while debugging a graft but must not leak into the build worktree.
find . -name '*.orig' -delete

# --- 7) empty the protected-exports ABI lists so vendor modules (wifi/bt) still
# load after susfs's symbol/CRC changes. Standard for susfs+GKI; matches the
# proven build-susfs173.yml. Without this, a shifted CRC on a protected symbol
# fails the KMI check and stock vendor_dlkm modules won't load -> boot failure.
for f in android/abi_gki_protected_exports_aarch64 android/abi_gki_protected_exports_x86_64; do
  [ -f "$f" ] && : > "$f" && echo "  [+] emptied $f"
done

REJ="$(find . -name '*.rej' 2>/dev/null || true)"
if [ -n "$REJ" ]; then echo "[!] REJECTS:"; for r in $REJ; do echo "== $r =="; cat "$r"; done; exit 1; fi
# --- 3e) services.c: force Android route-netlink boundaries ---
# Duck Detector's "permission boundary check" reads RTM_GETLINK and RTM_GETNEIGH
# from the app domain and receives the physical wlan0 MAC and the LAN neighbour
# table. AOSP policy is meant to deny both for untrusted_app; CTS checks it.
#
# Mechanism, all in security/selinux:
#   policydb_read()  sets p->android_netlink_route / _getneigh from the policy
#                    config word (byte offset 20 of the blob).
#   services.c       copies those into selinux_state.
#   nlmsgtab.c       selinux_nlmsg_init() then maps:
#                      flag=1 -> RTM_GETLINK  = nlmsg_readpriv   (app lacks it)
#                      flag=0 -> RTM_GETLINK  = nlmsg_read       (app HAS it)
#                    and likewise RTM_GETNEIGH/RTM_GETNEIGHTBL:
#                      nlmsg_getneigh vs nlmsg_read.
#
# Measured on device: the crDroid policy ships config word = 1 (MLS only, both
# Android netlink bits clear), so both flags land at 0 and every app can read
# the MAC and ARP. KernelSU's own fixup in sepolicy.c ORs the bits into an
# intermediate buffer during early init, which does not survive the final
# policy load.
#
# Fix: force both flags at every policy load. Exactly three message types
# change mapping (RTM_GETLINK, RTM_GETNEIGH, RTM_GETNEIGHTBL); RTM_GETADDR,
# RTM_GETROUTE and RTM_GETRULE keep nlmsg_read, so getifaddrs() and route
# enumeration keep working. su/ksu are untouched: KernelSU gives
# KERNEL_SU_DOMAIN "allow ALL ALL ALL" plus permissive, so root tooling keeps
# full netlink access. Verified: this tree's 50_ patch does not touch
# security/selinux/ss/services.c, so there is no patch conflict.
python3 - "$KROOT/security/selinux/ss/services.c" <<'PY'
import sys

f = sys.argv[1]
code = open(f, encoding="utf-8").read()

if 'NETLINK_BOUNDARY_FIX' in code:
    print("  [=] services.c already patched (NETLINK_BOUNDARY_FIX present)")
    sys.exit(0)

old = ("\tstate->android_netlink_route = p->android_netlink_route;\n"
       "\tstate->android_netlink_getneigh = p->android_netlink_getneigh;\n")
assert old in code, "services.c android_netlink assignment not found"

new = ("\t/* NETLINK_BOUNDARY_FIX (Nexus crdroid16 patch): the shipped policy\n"
       "\t * omits the Android route-netlink config bits, which maps RTM_GETLINK\n"
       "\t * and RTM_GETNEIGH to nlmsg_read -- a permission untrusted_app holds --\n"
       "\t * leaking the physical MAC and the ARP/neighbour table to every app.\n"
       "\t * Force the restricted mapping on every policy load. Only those three\n"
       "\t * message types are affected; RTM_GETADDR/GETROUTE/GETRULE keep\n"
       "\t * nlmsg_read, and su/ksu keep full access via KERNEL_SU_DOMAIN. */\n"
       "\tp->android_netlink_route = 1;\n"
       "\tp->android_netlink_getneigh = 1;\n"
       "\tstate->android_netlink_route = p->android_netlink_route;\n"
       "\tstate->android_netlink_getneigh = p->android_netlink_getneigh;\n")

code = code.replace(old, new, 1)
assert code.count("p->android_netlink_route = 1;") == 1
open(f, "w", encoding="utf-8").write(code)
print("  [+] services.c: netlink boundary forced (policydb + state)")
PY

echo "[*] integration complete, no rejects"
