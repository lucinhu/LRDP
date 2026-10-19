"""Explicit allowlist for the workspace's isolated Android test devices.

The dedicated ADB server and serial are fixed. Selecting an OS never permits
running tests on a personal phone or the user's default ADB server.
"""
from dataclasses import dataclass
import re


@dataclass(frozen=True)
class TestDevice:
    key: str
    avd: str
    api: int
    page_size: int

    @property
    def platform(self):
        return f'Android API{self.api} x86_64 {self.page_size // 1024}KiB'

    def runtime(self, stem):
        return f'build/android-{stem}-runtime' if self.key == 'api36' else f'build/android-{self.key}-{stem}-runtime'

    def verify(self, android):
        assert self.avd in android('emu', 'avd', 'name').stdout.splitlines(), 'Wrong owned AVD'
        assert android('shell', 'getprop', 'sys.boot_completed').stdout.strip() == '1'
        assert android('shell', 'getprop', 'ro.build.version.sdk').stdout.strip() == str(self.api)
        assert android('shell', 'getprop', 'ro.product.cpu.abi').stdout.strip() == 'x86_64'
        page = android('shell', 'getconf', 'PAGE_SIZE', check=False)
        if page.returncode == 0 and page.stdout.strip().isdigit():
            actual_page = int(page.stdout.strip())
            page_probe = 'getconf PAGE_SIZE'
        else:
            # Old Android images do not ship getconf. Read the kernel's own
            # mapping metadata rather than assuming their page size.
            mappings = android('shell', 'cat', '/proc/self/smaps').stdout
            sizes = {int(value) * 1024 for value in re.findall(
                r'^KernelPageSize:\s+(\d+)\s+kB', mappings, re.M)}
            assert sizes == {self.page_size}, sizes
            actual_page = next(iter(sizes))
            page_probe = '/proc/self/smaps KernelPageSize'
        assert actual_page == self.page_size
        assert android('shell', 'id', '-u').stdout.strip() == '2000', 'Use unrooted adbd'
        return {'avd': self.avd, 'api': self.api, 'abi': 'x86_64', 'page_size': self.page_size,
                'adb_port': 5038, 'serial': 'emulator-5556', 'shell_uid': 2000,
                'page_size_probe': page_probe,
                'build_fingerprint': android('shell', 'getprop', 'ro.build.fingerprint').stdout.strip()}


DEVICES = {'api36': TestDevice('api36', 'LRDP_API36_16k', 36, 16384),
           'api25': TestDevice('api25', 'LRDP_API25_x64', 25, 4096)}


def add_device_argument(parser):
    parser.add_argument('--device', choices=tuple(DEVICES), default='api36',
                        help='Owned AVD profile on ADB 5038 / emulator-5556')


def screenshot_mapping(android, image_size):
    """Map logical display coordinates to an OS screenshot, excluding no insets."""
    output = android('shell', 'wm', 'size').stdout
    sizes = re.findall(r'(?:Physical|Override) size:\s*(\d+)x(\d+)', output)
    assert sizes, output
    width, height = map(int, sizes[-1])
    actual_width, actual_height = image_size
    if (width > height) != (actual_width > actual_height):
        width, height = height, width
    scale = actual_width / width
    assert abs(scale - actual_height / height) < .01, (image_size, width, height)
    return scale, {'logical_display': [width, height],
                   'screenshot': [actual_width, actual_height], 'scale': scale}
