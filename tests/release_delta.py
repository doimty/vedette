from pathlib import Path
import subprocess
ROOT=Path(__file__).resolve().parents[1]
BASE='de411f7917d529de91c947312ce3cf6eb07bf161'
NAMES={'Makefile','vedetteprefs/Makefile','control','.github/workflows/roothide-build.yml'}
OLD_TARGET='ifeq ($(THEOS_PACKAGE_SCHEME),roothide)\nTARGET := iphone:clang:16.5:15.0\nelse\nTARGET := iphone:clang:latest:7.0\nendif\n'
MATRIX='''    name: Package (${{ matrix.scheme }})
    runs-on: macos-14
    strategy:
      fail-fast: false
      matrix:
        include:
          - scheme: roothide
            package_arch: iphoneos-arm64e
            prefix: ''
          - scheme: rootless
            package_arch: iphoneos-arm64
            prefix: '/var/jb'
'''

def expected_release(name,data):
    text=data.decode()
    def change(old,new,count=1):
        nonlocal text
        assert text.count(old)==count,(name,old,text.count(old))
        text=text.replace(old,new)
    if name=='Makefile':
        change('THEOS_PACKAGE_SCHEME = roothide','THEOS_PACKAGE_SCHEME ?= roothide')
        change(OLD_TARGET,'ifeq ($(filter $(THEOS_PACKAGE_SCHEME),roothide rootless),)\n$(error Supported package schemes: roothide rootless)\nendif\nexport TARGET = iphone:clang:16.5:15.0\n')
        change('include $(THEOS_MAKE_PATH)/aggregate.mk\n','include $(THEOS_MAKE_PATH)/aggregate.mk\n\nbefore-package::\n\tpython3 ci/stage_release.py --scheme "$(THEOS_PACKAGE_SCHEME)" --stage "$(THEOS_STAGING_DIR)"\n')
    elif name=='vedetteprefs/Makefile':
        change(OLD_TARGET,'TARGET := iphone:clang:16.5:15.0\n')
        change('ifeq ($(THEOS_PACKAGE_SCHEME),roothide)\nVedettePrefs_LDFLAGS += -F$(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks\nendif\n','VedettePrefs_LDFLAGS += -F$(THEOS)/sdks/iPhoneOS16.5.sdk/System/Library/PrivateFrameworks\n')
    elif name=='control':
        change('Version: 1.1.11-1+nice2','Version: 1.1.12-2')
        change('Description: Monitor CPU hogging processes','Description: 按应用与守护进程独立管理 CPU 限制和 nice 调度优先级')
        change('Depends: roothide,','Depends: firmware (>= 15.0), roothide,')
        change('https://udevsharold.github.io/repo/depictions/com.udevs.vedette/icon/icon.png','https://doimty.github.io/icons/com.doimty.vedette.png')
        change('https://udevsharold.github.io/repo/depictions/?p=com.udevs.vedette','https://doimty.github.io/depictions/com.doimty.vedette/')
    elif name=='.github/workflows/roothide-build.yml':
        change('name: Build Vedette roothide','name: Build Vedette rootless and roothide')
        change('    name: Package (roothide)\n    runs-on: macos-14\n',MATRIX)
        change('      THEOS_PACKAGE_SCHEME: roothide\n','      THEOS_PACKAGE_SCHEME: ${{ matrix.scheme }}\n      PACKAGE_ARCH: ${{ matrix.package_arch }}\n      PACKAGE_PREFIX: ${{ matrix.prefix }}\n      PACKAGE_VERSION: 1.1.12-2\n')
        change('mkdir -p "$THEOS/vendor/include/AltList" "$THEOS/vendor/lib" "$THEOS/vendor/lib/iphone/roothide"','mkdir -p "$THEOS/vendor/include/AltList" "$THEOS/vendor/lib" "$THEOS/vendor/lib/iphone/$THEOS_PACKAGE_SCHEME"')
        change('cp -R /tmp/AltList/.theos/obj/AltList.framework "$THEOS/vendor/lib/iphone/roothide/"','cp -R /tmp/AltList/.theos/obj/AltList.framework "$THEOS/vendor/lib/iphone/$THEOS_PACKAGE_SCHEME/"')
        change('make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME=roothide TARGET=','make package FINALPACKAGE=1 THEOS_PACKAGE_SCHEME="$THEOS_PACKAGE_SCHEME" TARGET=')
        change('python3 -B tests/canonicalize_nice_deb.py packages/com.doimty.vedette_1.1.11-1+nice2_iphoneos-arm64e.deb','python3 -B tests/canonicalize_nice_deb.py "packages/com.doimty.vedette_${PACKAGE_VERSION}_${PACKAGE_ARCH}.deb" "$THEOS_PACKAGE_SCHEME"')
        change('- name: Verify roothide artifact','- name: Verify package artifact')
        change('deb="packages/com.doimty.vedette_1.1.11-1+nice2_iphoneos-arm64e.deb"','deb="packages/com.doimty.vedette_${PACKAGE_VERSION}_${PACKAGE_ARCH}.deb"')
        change('= "1.1.11-1+nice2"','= "$PACKAGE_VERSION"')
        change('= "iphoneos-arm64e"','= "$PACKAGE_ARCH"')
        change('= "/Library/MobileSubstrate/DynamicLibraries/Vedette.dylib"','= "$PACKAGE_PREFIX/Library/MobileSubstrate/DynamicLibraries/Vedette.dylib"')
        change('= "/Library/PreferenceBundles/VedettePrefs.bundle/VedettePrefs"','= "$PACKAGE_PREFIX/Library/PreferenceBundles/VedettePrefs.bundle/VedettePrefs"')
        change('          otool -D "$dylib" | grep -q \'@loader_path/.jbroot/\'\n','          if [ "$THEOS_PACKAGE_SCHEME" = roothide ]; then\n            otool -D "$dylib" | grep -q \'@loader_path/.jbroot/\'\n          else\n            otool -D "$dylib" | grep -q \'@rpath/Vedette.dylib\'\n          fi\n')
        change('python3 -B tests/verify_nice_archive.py "$deb"','python3 -B tests/verify_nice_archive.py "$deb" "$THEOS_PACKAGE_SCHEME"')
        change('nicectl="/tmp/vedette-package/usr/libexec/vedette-nicectl"','nicectl="/tmp/vedette-package$PACKAGE_PREFIX/usr/libexec/vedette-nicectl"')
        change('python3 -B tests/verify_preferences_resources.py /tmp/vedette-package','python3 -B tests/verify_preferences_resources.py "/tmp/vedette-package$PACKAGE_PREFIX"\n          python3 -B tests/verify_release_layout.py "$deb" "$THEOS_PACKAGE_SCHEME"')
        change('          name: vedette-roothide-packages','          name: vedette-${{ matrix.scheme }}-packages')
        change('          sudo bash tests/run_nice_native_tests.sh\n','          sudo bash tests/run_nice_native_tests.sh\n          sudo bash tests/run_springboard_native_tests.sh\n')
    return text.encode()

def without_release(name,actual):
    from springboard_delta import without_springboard
    actual=without_springboard(name,actual)
    if name not in NAMES: return actual
    original=subprocess.check_output(['git','show',BASE+':'+name],cwd=ROOT)
    assert actual==expected_release(name,original),'Unexpected release change: '+name
    return original
