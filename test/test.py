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

    assert dut.bus.value == 0, f"Expected bus=0 after reset, got {dut.bus.value}"


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
        assert dut.bus.value == expected, (
            f"Cycle {expected}: expected bus={expected}, got {dut.bus.value}"
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

    prior_value = dut.bus.value
    dut._log.info(f"prior value: {prior_value}")

    dut.ena.value = 0

    await ClockCycles(dut.clk, 3)
    await FallingEdge(dut.clk)

    assert dut.bus.value == "ZZZZZZZZ", (
        f"Expected bus to hold at ZZZZ ZZZZ, got {dut.bus.value}"
    )

    assert dut.bus.value != prior_value, (
        f"Expected bus to hold at ZZZZ ZZZZ, got {prior_value}"
    )
