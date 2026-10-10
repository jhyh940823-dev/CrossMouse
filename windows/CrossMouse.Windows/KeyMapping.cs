namespace CrossMouse.Windows;

/// <summary>
/// Apple ANSI virtual keycodes -> Windows Set 1 physical scan codes.
/// Extended keys use bit 8 (0x100). Mac Command maps to Windows Ctrl to
/// preserve Cmd+C/V muscle memory; Mac Control maps to the Windows logo key.
/// Physical key events let the Windows keyboard layout/IME do character input.
/// </summary>
internal static class KeyMapping
{
    private static readonly IReadOnlyDictionary<int, int> ScanCodes = new Dictionary<int, int>
    {
        [0] = 0x1E, [1] = 0x1F, [2] = 0x20, [3] = 0x21,
        [4] = 0x23, [5] = 0x22, [6] = 0x2C, [7] = 0x2D,
        [8] = 0x2E, [9] = 0x2F, [11] = 0x30, [12] = 0x10,
        [13] = 0x11, [14] = 0x12, [15] = 0x13, [16] = 0x15,
        [17] = 0x14, [18] = 0x02, [19] = 0x03, [20] = 0x04,
        [21] = 0x05, [22] = 0x07, [23] = 0x06, [24] = 0x0D,
        [25] = 0x0A, [26] = 0x08, [27] = 0x0C, [28] = 0x09,
        [29] = 0x0B, [30] = 0x1B, [31] = 0x18, [32] = 0x16,
        [33] = 0x1A, [34] = 0x17, [35] = 0x19, [36] = 0x1C,
        [37] = 0x26, [38] = 0x24, [39] = 0x28, [40] = 0x25,
        [41] = 0x27, [42] = 0x2B, [43] = 0x33, [44] = 0x35,
        [45] = 0x31, [46] = 0x32, [47] = 0x34, [48] = 0x0F,
        [49] = 0x39, [50] = 0x29, [51] = 0x0E, [53] = 0x01,
        [54] = 0x11D, [55] = 0x1D, // Command -> Control
        [56] = 0x2A, [57] = 0x3A, [58] = 0x38,
        [59] = 0x15B, [60] = 0x36, [61] = 0x138,
        [62] = 0x15C, // Mac Control -> Windows logo
        [65] = 0x53, [67] = 0x37, [69] = 0x4E, [71] = 0x45,
        [75] = 0x135, [76] = 0x11C, [78] = 0x4A,
        [82] = 0x52, [83] = 0x4F, [84] = 0x50, [85] = 0x51,
        [86] = 0x4B, [87] = 0x4C, [88] = 0x4D, [89] = 0x47,
        [91] = 0x48, [92] = 0x49,
        [96] = 0x3F, [97] = 0x40, [98] = 0x41, [99] = 0x3D,
        [100] = 0x42, [101] = 0x43, [103] = 0x57, [109] = 0x44,
        [111] = 0x58, [115] = 0x147, [116] = 0x149, [117] = 0x153,
        [118] = 0x3E, [119] = 0x14F, [120] = 0x3C, [121] = 0x151,
        [122] = 0x3B, [123] = 0x14B, [124] = 0x14D,
        [125] = 0x150, [126] = 0x148
    };

    public static bool TryGet(int macKeyCode, out int scanCode) =>
        ScanCodes.TryGetValue(macKeyCode, out scanCode);
}
