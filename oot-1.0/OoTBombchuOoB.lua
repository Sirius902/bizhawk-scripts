-- OoT 1.0 VRAM address for Overlay_Load
local overlay_load_ram = 0x800CCBB8

-- OoT 1.0 VRAM address for gActorOverlayTable
local actor_overlay_table_ram = 0x800E8530

-- ACTOR_EN_BOM_CHU
local actor_id_bombchu = 0x00DA

-- sizeof(ActorOverlay)
local actor_overlay_size = 0x20

-- offsetof(ActorOverlay, loadedRamAddr)
local actor_overlay_loaded_ram_addr_off = 0x10

-- offsetof(ActorOverlay, romFile) + offsetof(RomFile, vromStart)
local actor_overlay_vrom_start_off = 0x0

-- offsetof(ActorOverlay, romFile) + offsetof(RomFile, vromEnd)
local actor_overlay_vrom_end_off = 0x4

-- VRAM address of hooked Bombchu overlay.
local bombchu_hooked_loaded_ram_addr = nil

-- VRAM address of hooked EnBomChu_UpdateFloorPoly.
local bombchu_update_floor_poly_ram = nil

-- Hook for EnBomChu_UpdateFloorPoly hook if any. nil otherwise.
local bombchu_update_floor_poly_hook = nil

local function getregister(reg)
  return emu.getregister(reg .. "_lo") & 0xFFFFFFFF
end

local function rdram(vram)
  return vram - 0x80000000
end

local function on_overlay_load()
  local vrom_start = getregister("a0")
  local vrom_end = getregister("a1")
  -- local vram_start = getregister("a2")
  -- local vram_end = getregister("a3")
  local allocated_ram_addr = memory.read_u32_be(rdram(getregister("sp")) + 0x10, "RDRAM")

  local bombchu_overlay_entry = actor_overlay_table_ram + (actor_overlay_size * actor_id_bombchu)

  local bombchu_overlay_vrom_start =
    memory.read_u32_be(rdram(bombchu_overlay_entry + actor_overlay_vrom_start_off), "RDRAM")
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
