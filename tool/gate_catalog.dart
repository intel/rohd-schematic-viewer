// Copyright (C) 2026 Intel Corporation
// SPDX-License-Identifier: BSD-3-Clause
//
// gate_catalog.dart
// Structural catalog of ROHD gate APIs for schematic rendering tests.
//
// 2026 August
// Author: Desmond Kirkpatrick <desmond.a.kirkpatrick@intel.com>

import 'package:rohd/rohd.dart';

/// A synthesizable catalog of representative ROHD gates.
///
/// Every result is connected to a top-level output so synthesis cannot prune
/// the cell that produces it.
class GateCatalog extends Module {
  /// Creates a gate catalog driven by caller-owned input signals.
  GateCatalog({
    required Logic clk,
    required Logic en,
    required Logic reset,
    required Logic muxSel,
    required Logic enableTri,
    required Logic a4,
    required Logic b4,
    required Logic a8,
    required Logic b8,
    required Logic d4,
    required Logic shamt4,
    required Logic idx3,
    required Logic idx5,
    required Logic resetValueDyn4,
    required LogicNet busNet,
  }) : super(name: 'gate_catalog', definitionName: 'GateCatalog') {
    clk = addInput('clk', clk);
    en = addInput('en', en);
    reset = addInput('reset', reset);
    muxSel = addInput('muxSel', muxSel);
    enableTri = addInput('enableTri', enableTri);
    a4 = addInput('a4', a4, width: 4);
    b4 = addInput('b4', b4, width: 4);
    a8 = addInput('a8', a8, width: 8);
    b8 = addInput('b8', b8, width: 8);
    d4 = addInput('d4', d4, width: 4);
    shamt4 = addInput('shamt4', shamt4, width: 4);
    idx3 = addInput('idx3', idx3, width: 3);
    idx5 = addInput('idx5', idx5, width: 5);
    resetValueDyn4 = addInput(
      'resetValueDyn4',
      resetValueDyn4,
      width: 4,
    );
    final bus = addInOut('bus', busNet, width: 8);

    addOutput('not_out', width: 8) <= ~a8;
    addOutput('and_ll_out', width: 8) <= a8 & b8;
    addOutput('and_lc_out', width: 8) <=
        And2Gate(a8, Const(0xaa, width: 8)).out;
    addOutput('or_ll_out', width: 8) <= a8 | b8;
    addOutput('or_lc_out', width: 8) <= Or2Gate(a8, Const(0x55, width: 8)).out;
    addOutput('xor_ll_out', width: 8) <= a8 ^ b8;
    addOutput('xor_lc_out', width: 8) <=
        Xor2Gate(a8, Const(0x0f, width: 8)).out;
    addOutput('reduce_and_out') <= a8.and();
    addOutput('reduce_or_out') <= a8.or();
    addOutput('reduce_xor_out') <= a8.xor();

    final addLl = Add(a4, b4);
    addOutput('add_ll_sum', width: 4) <= addLl.sum;
    addOutput('add_ll_carry') <= addLl.carry;
    final addLc = Add(a4, 5);
    addOutput('add_lc_sum', width: 4) <= addLc.sum;
    addOutput('add_lc_carry') <= addLc.carry;
    addOutput('sub_ll_out', width: 4) <= a4 - b4;
    addOutput('sub_lc_out', width: 4) <= a4 - 3;
    addOutput('mul_ll_out', width: 4) <= a4 * b4;
    addOutput('mul_lc_out', width: 4) <= a4 * 3;
    addOutput('div_ll_out', width: 4) <= a4 / b4;
    addOutput('div_lc_out', width: 4) <= a4 / 3;
    addOutput('mod_ll_out', width: 4) <= a4 % b4;
    addOutput('mod_lc_out', width: 4) <= a4 % 3;
    addOutput('pow_ll_out', width: 4) <= a4.pow(b4);
    addOutput('pow_lc_out', width: 4) <= a4.pow(3);

    addOutput('eq_ll_out') <= a4.eq(b4);
    addOutput('eq_lc_out') <= a4.eq(5);
    addOutput('neq_ll_out') <= a4.neq(b4);
    addOutput('neq_lc_out') <= a4.neq(5);
    addOutput('lt_ll_out') <= a4.lt(b4);
    addOutput('lt_lc_out') <= a4.lt(5);
    addOutput('gt_ll_out') <= (a4 > b4);
    addOutput('gt_lc_out') <= (a4 > 5);
    addOutput('le_ll_out') <= a4.lte(b4);
    addOutput('le_lc_out') <= a4.lte(5);
    addOutput('ge_ll_out') <= (a4 >= b4);
    addOutput('ge_lc_out') <= (a4 >= 5);

    addOutput('lshift_ll_out', width: 4) <= LShift(a4, shamt4).out;
    addOutput('lshift_lc_out', width: 4) <= LShift(a4, 2).out;
    addOutput('rshift_ll_out', width: 4) <= RShift(a4, shamt4).out;
    addOutput('rshift_lc_out', width: 4) <= RShift(a4, 2).out;
    addOutput('arshift_ll_out', width: 4) <= ARShift(a4, shamt4).out;
    addOutput('arshift_lc_out', width: 4) <= ARShift(a4, 2).out;

    addOutput('mux_class_out', width: 4) <= Mux(muxSel, a4, b4).out;
    addOutput('mux_fn_dynamic_out', width: 4) <= mux(muxSel, a4, b4);
    addOutput('mux_fn_const1_out', width: 4) <= mux(Const(1, width: 1), a4, b4);
    addOutput('mux_fn_const0_out', width: 4) <= mux(Const(0, width: 1), a4, b4);

    addOutput('index_natural_out') <= a8[idx3];
    addOutput('index_oversized_out') <= a8[idx5];
    addOutput('replicate_x3_out', width: 12) <= a4.replicate(3);
    addOutput('replicate_x5_out', width: 20) <= a4.replicate(5);
    addOutput('slice_out', width: 4) <= a8.getRange(2, 6);
    addOutput('swizzle_out', width: 8) <= [a4, b4].swizzle();

    TriStateBuffer(a8, enable: enableTri, name: 'tsb').out.gets(bus);
    addOutput('tribuf_readback_out', width: 8) <= bus;

    addOutput('q_dff', width: 4) <= flop(clk, d4);
    addOutput('q_dffe', width: 4) <= flop(clk, d4, en: en);
    addOutput('q_sdff', width: 4) <= flop(clk, d4, reset: reset, resetValue: 9);
    addOutput('q_sdffe', width: 4) <=
        flop(clk, d4, en: en, reset: reset, resetValue: 9);
    addOutput('q_adff', width: 4) <=
        flop(clk, d4, reset: reset, resetValue: 9, asyncReset: true);
    addOutput('q_adffe', width: 4) <=
        flop(clk, d4, en: en, reset: reset, resetValue: 9, asyncReset: true);
    addOutput('q_aldff', width: 4) <=
        flop(clk, d4,
            reset: reset, resetValue: resetValueDyn4, asyncReset: true);
    addOutput('q_aldffe', width: 4) <=
        flop(clk, d4,
            en: en, reset: reset, resetValue: resetValueDyn4, asyncReset: true);
    addOutput('q_dynsync_noen', width: 4) <=
        flop(clk, d4, reset: reset, resetValue: resetValueDyn4);
    addOutput('q_dynsync_en', width: 4) <=
        flop(clk, d4, en: en, reset: reset, resetValue: resetValueDyn4);
  }
}
