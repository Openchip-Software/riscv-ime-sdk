/* SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
 * SPDX-License-Identifier: Apache-2.0 */
#include <stdio.h>

int lto_square(int x);

int main(void)
{
    printf("lto %d\n", lto_square(7));
    return 0;
}
