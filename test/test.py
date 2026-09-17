import cocotb
from cocotb.clock import Clock
from cocotb.triggers import RisingEdge, FallingEdge, ClockCycles


@cocotb.test()
async def test_reset(dut):
    """Counter should be 0 immediately after reset."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 2)

    dut.rst_n.value = 1
    dut.ena.value = 1
    await RisingEdge(dut.clk)

    assert dut.uo_out.value == 0, f"Expected uo_out=0 after reset, got {dut.uo_out.value}"


@cocotb.test()
async def test_count_up(dut):
    """Counter should increment by 1 each cycle while enable is high."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    dut.rst_n.value = 0
    dut.ena.value = 0
    await ClockCycles(dut.clk, 2)

    dut.rst_n.value = 1
    dut.ena.value = 1

    for expected in range(1, 6):
        await RisingEdge(dut.clk)
        # settle after the clocked update
        await FallingEdge(dut.clk)
        assert dut.uo_out.value == expected, (
            f"Cycle {expected}: expected uo_out={expected}, got {dut.uo_out.value}"
        )


@cocotb.test()
async def test_enable_low_output_z_value(dut):
    """Counter should hold its value while enable is low."""
    clock = Clock(dut.clk, 10, unit="ns")
    cocotb.start_soon(clock.start())

    dut.rst_n.value = 0
    dut.ena.value = 0
    await ClockCycles(dut.clk, 2)

    dut.rst_n.value = 1
    dut.ena.value = 1
    await ClockCycles(dut.clk, 3)
    await FallingEdge(dut.clk)

    dut._log.info(f"uo_out {dut.uo_out.value}")
    dut._log.info(f"ena {dut.ena.value}")
    dut.ena.value = 0

    await ClockCycles(dut.clk, 3)
    await FallingEdge(dut.clk)

    dut._log.info(f"uo_out {dut.uo_out.value}")
    dut._log.info(f"ena {dut.ena.value}")

    assert dut.uo_out.value == "ZZZZZZZZ", (
        f"Expected bus to hold at ZZZZ ZZZZ, got {dut.uo_out.value}"
    )
