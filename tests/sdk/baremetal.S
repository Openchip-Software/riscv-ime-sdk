/* SPDX-FileCopyrightText: 2026 Openchip and Software Technologies, S.L.
 * SPDX-License-Identifier: Apache-2.0
 *
 * Bare-metal test of qemu-system-riscv32 and qemu-system-riscv64 on the
 * virt machine: print "baremetal ok" on the NS16550 UART, then write
 * FINISHER_PASS to the SiFive test device, which exits QEMU with status 0.
 */
    .section .text
    .globl _start
_start:
    li      t0, 0x10000000
    la      t1, message
1:  lbu     t2, 0(t1)
    beqz    t2, 2f
    sb      t2, 0(t0)
    addi    t1, t1, 1
    j       1b
2:  li      t0, 0x100000
    li      t1, 0x5555
    sw      t1, 0(t0)
3:  j       3b

    .section .rodata
message:
    .asciz  "baremetal ok\n"
