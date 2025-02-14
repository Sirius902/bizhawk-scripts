-- FUTURE(Sirius902) Make this work on all versions of OoT by sigscanning Overlay_Load and gActorOverlayTable.
-- Plus come up with better sig that works between versions for EnBomChu_UpdateFloorPoly to search for within
-- ovl_En_Bom_Chu.

---OoT 1.0 VRAM address for Overlay_Load
local overlay_load_ram = 0x800CCBB8

---OoT 1.0 VRAM address for gActorOverlayTable
local actor_overlay_table_ram = 0x800E8530

---ACTOR_EN_BOM_CHU
local actor_id_bombchu = 0x00DA

---sizeof(ActorOverlay)
local actor_overlay_size = 0x20

---offsetof(ActorOverlay, loadedRamAddr)
local actor_overlay_loaded_ram_addr_off = 0x10

---offsetof(ActorOverlay, romFile) + offsetof(RomFile, vromStart)
local actor_overlay_vrom_start_off = 0x0

---offsetof(ActorOverlay, romFile) + offsetof(RomFile, vromEnd)
local actor_overlay_vrom_end_off = 0x4

---VRAM address of hooked Bombchu overlay.
---@type integer|nil
local bombchu_hooked_loaded_ram_addr = nil

---VRAM address of hooked EnBomChu_UpdateFloorPoly.
---@type integer|nil
local bombchu_update_floor_poly_ram = nil

---Hook for EnBomChu_UpdateFloorPoly.
---@type string|nil
local bombchu_update_floor_poly_hook = nil

---Get the lower dword of a register as a u32.
---@param reg string The register name.
---@return integer value The value of the register as a u32.
local function getregister(reg)
  return emu.getregister(reg .. "_lo") & 0xFFFFFFFF
end

---Get the RDRAM address from a VRAM address.
---@param vram integer
---@return integer rdram The RDRAM address for `vram`.
local function rdram(vram)
  return vram - 0x80000000
end

---When an overlay begins loading, check if it's the Bombchu overlay. If so, hook
---EnBomChu_UpdateFloorPoly and early return if the floor poly is null to prevent
---a crash when exploding Bombchus out of bounds.
local function on_overlay_load()
  local vrom_start = getregister("a0")
  local vrom_end = getregister("a1")
  -- local vram_start = getregister("a2")
  -- local vram_end = getregister("a3")
  local allocated_ram_addr = memory.read_u32_be(rdram(getregister("sp")) + 0x10, "RDRAM")

  local bombchu_overlay_entry = actor_overlay_table_ram + (actor_overlay_size * actor_id_bombchu)

  ---Start of ovl_En_Bom_Chu in VROM.
  local bombchu_overlay_vrom_start =
    memory.read_u32_be(rdram(bombchu_overlay_entry + actor_overlay_vrom_start_off), "RDRAM")

  ---End of ovl_En_Bom_Chu in VROM.
  local bombchu_overlay_vrom_end =
    memory.read_u32_be(rdram(bombchu_overlay_entry + actor_overlay_vrom_end_off), "RDRAM")

  if vrom_start == bombchu_overlay_vrom_start and vrom_end == bombchu_overlay_vrom_end then
    local function unhook()
      event.unregisterbyid(bombchu_update_floor_poly_hook)

      bombchu_update_floor_poly_hook = nil
      bombchu_hooked_loaded_ram_addr = nil
      bombchu_update_floor_poly_ram = nil
    end

    if bombchu_update_floor_poly_hook ~= nil then
      unhook()
    end

    -- Once we've returned from Overlay_Load, find EnBomChu_UpdateFloorPoly.
    local ra = getregister("ra")
    local ra_hook = nil
    ra_hook = event.on_bus_exec(function()
      event.unregisterbyid(ra_hook)

      local overlay_size = ((vrom_end - (vrom_end % 4)) - vrom_start)
      for i = allocated_ram_addr, allocated_ram_addr + overlay_size, 4 do
        local inst = memory.read_u32_be(rdram(i), "RDRAM")

        -- FUTURE(Sirius902) This sucks ass, use a sigscan instead.

        -- Start of EnBomChu_UpdateFloorPoly.
        -- addiu $sp, $sp, -0x90
        if inst == 0x27BDFF70 then
          bombchu_update_floor_poly_ram = i
        end

        if bombchu_update_floor_poly_ram ~= nil then
          break
        end
      end

      bombchu_hooked_loaded_ram_addr = allocated_ram_addr

      bombchu_update_floor_poly_hook = event.on_bus_exec(function()
        bombchu_overlay_entry = actor_overlay_table_ram + (actor_overlay_size * actor_id_bombchu)
        local bombchu_loaded_ram_addr =
          memory.read_u32_be(rdram(bombchu_overlay_entry + actor_overlay_loaded_ram_addr_off), "RDRAM")

        -- Unhook if the Bombchu overlay was unloaded or relocated.
        if bombchu_loaded_ram_addr ~= bombchu_hooked_loaded_ram_addr then
          unhook()
          return
        end

        -- Detect that the game would crash from null floor poly. Return immediately.
        local floor_poly = getregister("a1")
        if floor_poly == 0 then
          -- NOTE(Sirius902) I would LOVE to just do `emu.setregister("PC", getregister("ra"))`
          -- but setting registers is not implemented for Mupen64. The second best thing would
          -- be to just:
          --
          -- jr $ra
          -- nop
          --
          -- But unfortunately it seems the funny `event.on_bus_exec` hook is running *after* the
          -- instruction is already run so we have to undo the movement of the stack pointer before
          -- returning. Due to that hook the second and third instructions for our jr $ra and consider
          -- them our "first" and "second" hooked instructions.

          local first_inst = memory.read_u32_be(rdram(bombchu_update_floor_poly_ram + 4), "RDRAM")
          local second_inst = memory.read_u32_be(rdram(bombchu_update_floor_poly_ram + 8), "RDRAM")

          -- jr $ra
          memory.write_u32_be(rdram(bombchu_update_floor_poly_ram + 4), 0x03E00008, "RDRAM")
          -- addiu $sp, $sp, 0x90
          memory.write_u32_be(rdram(bombchu_update_floor_poly_ram + 8), 0x27BD0090, "RDRAM")

          -- Restore the instructions after returning.
          local ra_prime = getregister("ra")
          local ra_prime_hook = nil
          ra_prime_hook = event.on_bus_exec(function()
            event.unregisterbyid(ra_prime_hook)

            memory.write_u32_be(rdram(bombchu_update_floor_poly_ram + 4), first_inst, "RDRAM")
            memory.write_u32_be(rdram(bombchu_update_floor_poly_ram + 8), second_inst, "RDRAM")
          end, ra_prime)
        end
      end, bombchu_update_floor_poly_ram)
    end, ra)
  end
end

local function main()
  local on_overlay_load_hook = event.on_bus_exec(on_overlay_load, overlay_load_ram)

  event.onexit(function()
    event.unregisterbyid(on_overlay_load_hook)

    if bombchu_update_floor_poly_hook ~= nil then
      event.unregisterbyid(bombchu_update_floor_poly_hook)
    end
  end)

  while true do
    emu.frameadvance()
  end
end

main()
