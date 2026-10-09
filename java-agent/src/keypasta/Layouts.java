package keypasta;

import java.awt.event.KeyEvent;
import java.util.HashMap;
import java.util.Map;

/**
 * Key positions and keyboard layouts. A position is a PC scan code (set 1), which is also the
 * Linux key number for every key of the main block.
 */
final class Layouts {
    private Layouts() {
    }

    static final int SHIFT = 1;
    static final int ALTGR = 2;

    /**
     * US key code at each position of the main block, plus Tab and Space. iKVM's own US table
     * turns these into the USB code of exactly that position. The ISO key (left of Y) has no US
     * key code: VK_LESS, which iKVM maps to that position (USB 100).
     */
    static final Map<Integer, Integer> US_KEY = new HashMap<Integer, Integer>();

    static {
        int[] digits = {KeyEvent.VK_1, KeyEvent.VK_2, KeyEvent.VK_3, KeyEvent.VK_4, KeyEvent.VK_5,
            KeyEvent.VK_6, KeyEvent.VK_7, KeyEvent.VK_8, KeyEvent.VK_9, KeyEvent.VK_0};
        for (int i = 0; i < digits.length; i++)
            US_KEY.put(0x02 + i, digits[i]);
        US_KEY.put(0x0C, KeyEvent.VK_MINUS);
        US_KEY.put(0x0D, KeyEvent.VK_EQUALS);
        putLetters(0x10, "QWERTYUIOP");
        US_KEY.put(0x1A, KeyEvent.VK_OPEN_BRACKET);
        US_KEY.put(0x1B, KeyEvent.VK_CLOSE_BRACKET);
        putLetters(0x1E, "ASDFGHJKL");
        US_KEY.put(0x27, KeyEvent.VK_SEMICOLON);
        US_KEY.put(0x28, KeyEvent.VK_QUOTE);
        US_KEY.put(0x29, KeyEvent.VK_BACK_QUOTE);
        US_KEY.put(0x2B, KeyEvent.VK_BACK_SLASH);
        putLetters(0x2C, "ZXCVBNM");
        US_KEY.put(0x33, KeyEvent.VK_COMMA);
        US_KEY.put(0x34, KeyEvent.VK_PERIOD);
        US_KEY.put(0x35, KeyEvent.VK_SLASH);
        US_KEY.put(0x56, KeyEvent.VK_LESS);
    }

    /** Positions only used when pasting (same key code on every layout). */
    static final int TAB = 0x0F;
    static final int SPACE = 0x39;

    private static void putLetters(int first, String letters) {
        for (int i = 0; i < letters.length(); i++)
            US_KEY.put(first + i, (int) letters.charAt(i));
    }

    /** US key code for a position, also Tab and Space; -1 if none. */
    static int usKey(int position) {
        if (position == TAB)
            return KeyEvent.VK_TAB;
        if (position == SPACE)
            return KeyEvent.VK_SPACE;
        Integer vk = US_KEY.get(position);
        return vk == null ? -1 : vk;
    }

    /**
     * Swiss layouts: position, then the characters with no modifier, Shift and AltGr. Dead keys
     * and empty places are 0 (dead-key characters are pasted as alt codes).
     */
    private static final Object[][] SWISS_GERMAN = {
        {0x02, '1', '+', '¦'}, {0x03, '2', '"', '@'}, {0x04, '3', '*', '#'},
        {0x05, '4', 'ç', '°'}, {0x06, '5', '%', '§'}, {0x07, '6', '&', '¬'},
        {0x08, '7', '/', '|'}, {0x09, '8', '(', '¢'}, {0x0A, '9', ')', 0},
        {0x0B, '0', '=', 0}, {0x0C, '\'', '?', 0}, {0x0D, 0, 0, 0},
        {0x12, 'e', 'E', '€'},
        {0x1A, 'ü', 'è', '['}, {0x1B, 0, '!', ']'},
        {0x27, 'ö', 'é', 0}, {0x28, 'ä', 'à', '{'},
        {0x29, '§', '°', 0}, {0x2B, '$', '£', '}'},
        {0x33, ',', ';', 0}, {0x34, '.', ':', 0}, {0x35, '-', '_', 0},
        {0x56, '<', '>', '\\'},
        {TAB, '\t', 0, 0}, {SPACE, ' ', 0, 0},
    };

    /** Letters of the Swiss layouts (QWERTZ): position, letter (Shift: capital). */
    private static final String LETTERS_ROW1 = "qwertzuiop";
    private static final String LETTERS_ROW2 = "asdfghjkl";
    private static final String LETTERS_ROW3 = "yxcvbnm";

    /** Character -> {position, modifiers}, fewest modifiers first. */
    static Map<Character, int[]> swiss(boolean french) {
        Map<Character, int[]> table = new HashMap<Character, int[]>();
        for (int mods = 0; mods <= ALTGR; mods++) {
            if (mods == 0 || mods == SHIFT) {
                addLetters(table, 0x10, LETTERS_ROW1, mods);
                addLetters(table, 0x1E, LETTERS_ROW2, mods);
                addLetters(table, 0x2C, LETTERS_ROW3, mods);
            }
            for (Object[] row : SWISS_GERMAN) {
                int position = (Integer) row[0];
                Object value = row[1 + mods];
                // Swiss French: the umlauts and the accented letters swap places
                if (french && (position == 0x1A || position == 0x27 || position == 0x28) && mods != ALTGR)
                    value = row[1 + (mods == 0 ? SHIFT : 0)];
                if (!(value instanceof Character))
                    continue;
                char c = (Character) value;
                if (!table.containsKey(c))
                    table.put(c, new int[] {position, mods});
            }
        }
        return table;
    }

    private static void addLetters(Map<Character, int[]> table, int first, String letters, int mods) {
        for (int i = 0; i < letters.length(); i++) {
            char c = letters.charAt(i);
            if (mods == SHIFT)
                c = Character.toUpperCase(c);
            if (!table.containsKey(c))
                table.put(c, new int[] {first + i, mods});
        }
    }

    /**
     * macOS doesn't pass key positions to Java: key code -> position, for a known local layout.
     * Only for the key codes macOS's Java takes from the character (letters, digits, dead keys,
     * see KeyFix.position); all other keys get the US key code of their position already.
     */
    static Map<Integer, Integer> macPositions(String layout) {
        Map<Integer, Integer> map = new HashMap<Integer, Integer>();
        if (layout.equals("de-CH") || layout.equals("fr-CH")) {
            for (Map.Entry<Character, int[]> e : swiss(layout.equals("fr-CH")).entrySet()) {
                if (e.getValue()[1] != 0)
                    continue;
                int vk = KeyEvent.getExtendedKeyCodeForChar(e.getKey());
                if (vk != KeyEvent.VK_UNDEFINED && !map.containsKey(vk))
                    map.put(vk, e.getValue()[0]);
            }
            map.put(KeyEvent.VK_DEAD_CIRCUMFLEX, 0x0D);
            map.put(KeyEvent.VK_DEAD_GRAVE, 0x0D);      // Shift + the ^ key
            map.put(KeyEvent.VK_DEAD_DIAERESIS, 0x1B);
        }
        return map;
    }

    /** Windows-1252 characters 128-159: Unicode code point -> ANSI code. */
    static final Map<Integer, Integer> CP1252 = new HashMap<Integer, Integer>();

    static {
        int[] pairs = {0x20AC, 128, 0x201A, 130, 0x0192, 131, 0x201E, 132, 0x2026, 133, 0x2020, 134,
            0x2021, 135, 0x02C6, 136, 0x2030, 137, 0x0160, 138, 0x2039, 139, 0x0152, 140, 0x017D, 142,
            0x2018, 145, 0x2019, 146, 0x201C, 147, 0x201D, 148, 0x2022, 149, 0x2013, 150, 0x2014, 151,
            0x02DC, 152, 0x2122, 153, 0x0161, 154, 0x203A, 155, 0x0153, 156, 0x017E, 158, 0x0178, 159};
        for (int i = 0; i < pairs.length; i += 2)
            CP1252.put(pairs[i], pairs[i + 1]);
    }

    /**
     * Number typed on the numpad for a character, the same for both remote OS where possible:
     * Windows reads Alt+nnn as OEM code page and Alt+0nnn as ANSI, the Linux console reads both
     * as Unicode. So 160-255 always get the leading 0; only Windows-1252 128-159 differ.
     */
    static String altCodeDigits(int codePoint, boolean remoteWindows) {
        if (codePoint >= 160 && codePoint <= 255)
            return "0" + codePoint;
        if (remoteWindows && CP1252.containsKey(codePoint))
            return "0" + CP1252.get(codePoint);
        return String.valueOf(codePoint);
    }
}
