package org.yx6;

/**
 * What a plain YM2149 actually sees.
 *
 * <p>A YM6 file carries its special effects (SID voice, digidrum, sinus-SID,
 * sync-buzzer) in bits that the sound chip itself does not use: the top nibbles
 * of R1/R3, the top bits of R6/R7 and of the three volume registers, plus R14
 * and R15 as effect data. Version 0.1 of yx6 plays no effects, so those bits are
 * masked away here - once, at packing time. That is both correct (they are not
 * chip state) and cheaper: constant high bits compress better, and the player
 * needs no masking code at all.
 *
 * <p>The one register that is not a plain mask is R13, the envelope shape.
 * A YM frame stores {@code $FF} there to mean "leave the shape alone"; writing
 * any value to R13 restarts the envelope, so that marker has to survive packing
 * and be honoured by the player.
 *
 * <p>R7's two top bits are the chip's I/O port directions, not sound. They are
 * masked off here and the player supplies the ST's own value, because on an ST
 * port A drives the floppy select lines.
 */
public final class Ym2149 {

    /** Envelope shape value meaning "do not write R13 this frame". */
    public static final int NO_ENVELOPE_CHANGE = 0xFF;

    /** Register 13, the envelope shape. */
    public static final int ENVELOPE_SHAPE = 13;

    /**
     * Bits each register keeps: 8-bit fine tone, 4-bit coarse tone, 5-bit noise
     * period, 6-bit mixer, 4-bit volume plus the envelope-mode bit, and the
     * 16-bit envelope period.
     */
    private static final int[] MASK = {
        0xFF, 0x0F, 0xFF, 0x0F, 0xFF, 0x0F, 0x1F,
        0x3F, 0x1F, 0x1F, 0x1F, 0xFF, 0xFF, 0x0F,
    };

    private Ym2149() {}

    /** The value the chip would use, with every YM6 effect bit removed. */
    public static int mask(int register, int value) {
        if (register == ENVELOPE_SHAPE && (value & 0xFF) == NO_ENVELOPE_CHANGE) {
            return NO_ENVELOPE_CHANGE;
        }
        return value & MASK[register];
    }

    /** Masks a whole register vector, leaving the input untouched. */
    public static byte[] mask(int register, byte[] values) {
        byte[] masked = new byte[values.length];
        for (int i = 0; i < values.length; i++) {
            masked[i] = (byte) mask(register, values[i] & 0xFF);
        }
        return masked;
    }
}
