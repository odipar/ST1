package org.jx1;

import org.jspecify.annotations.Nullable;

/**
 * One block (literal run or match) in an optimal-parse chain; {@code offset == 0} means literals.
 *
 * <p>The C original ({@code zx1.h}, {@code memory.c}) manages these with a ref-counting pool
 * allocator; here the garbage collector makes that machinery unnecessary.
 */
public record Block(int bits, int index, int offset, @Nullable Block chain) {}
