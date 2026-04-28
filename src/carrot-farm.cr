require "rosegold"

# =============================================================================
# Carrot/Potato Farm Bot for RosegoldMC
# Harvests a rectangular farm field while holding right-click (Fortune III),
# periodically deposits items into a compactor chest, hits the furnace with a
# stick to trigger compaction, and announces completion via in-game chat.
#
# Ported from caroot.js (JsMacros) — improved to leverage Rosegold's
# start_using_hand + move_to for smooth harvesting without W-tapping.
# =============================================================================

# =============================================================================
# CONFIGURATION
# =============================================================================

SERVER_HOST   = ENV.fetch "SERVER_HOST", "play.civmc.net"
SPECTATE_HOST = ENV.fetch "SPECTATE_HOST", "0.0.0.0"
SPECTATE_PORT = ENV.fetch("SPECTATE_PORT", "25566").to_i

INITIAL_RETRY_DELAY = 5.seconds
MAX_RETRY_DELAY     = 5.minutes

# Farm boundaries (inclusive block coordinates)
X_WEST  = 7286
X_EAST  = 7385
Z_NORTH = 3117
Z_SOUTH = 3214

# Compactor positions
COMPACTOR_STAND_X   = 7293
COMPACTOR_STAND_Z   = 3214 # where the bot stands
COMPACTOR_CHEST_X   = 7294
COMPACTOR_CHEST_Z   = 3216 # chest block to open
COMPACTOR_FURNACE_X = 7292
COMPACTOR_FURNACE_Z = 3216 # furnace block to hit with stick

# How many rows to harvest between compactor visits
ROWS_PER_COMPACT = 4

# Announcement config
DISCORD_GROUP = "Ila'Kyavul"
FARM_NAME     = "Carrot farm"
REGROW_HOURS  = 32

# Pitch while farming (looking slightly downward at crops)
FARM_PITCH = 30.0

# Ticks to wait at each block for items to pop and be picked up.
# 40 ticks ≈ 2 seconds. Increase if you're losing items, decrease for speed.
HARVEST_WAIT_TICKS = 1

# Approximate seconds per row: each block takes ~(walk + wait) time
TIME_PER_ROW = (Z_SOUTH - Z_NORTH) * (HARVEST_WAIT_TICKS / 20.0 + 0.3) + 5.0

# =============================================================================
# HELPERS
# =============================================================================

def log(msg : String)
  puts "[#{Time.local.to_s("%H:%M:%S")}] #{msg}"
end

# Check if a slot has Fortune III enchantment
def fortune3?(slot : Rosegold::Slot) : Bool
  slot.enchantments.any? do |name, level|
    name.downcase.includes?("fortune") && level >= 3
  end
end

FORTUNE_III_SPEC = ->fortune3?(Rosegold::Slot)

# =============================================================================
# INVENTORY MANAGEMENT
# =============================================================================

def equip_fortune_tool!(bot : Rosegold::Bot)
  bot.inventory.pick!(FORTUNE_III_SPEC)
  log "Equipped Fortune III tool: #{bot.main_hand.name}"
end

def validate_inventory!(bot : Rosegold::Bot)
  has_fortune = bot.inventory.slots.any? { |slot| fortune3?(slot) }
  raise "Need a Fortune III tool in inventory" unless has_fortune
  raise "Need a stick in inventory" if bot.inventory.count("stick") == 0
end

# =============================================================================
# COMPACT — deposit harvested items & trigger compactor
# =============================================================================

def compact!(bot : Rosegold::Bot)
  log "Going to compactor..."

  # Walk to the compactor station
  bot.move_to(COMPACTOR_STAND_X, COMPACTOR_STAND_Z)

  # Look at the chest and interact
  bot.look_at Rosegold::Vec3d.new(
    COMPACTOR_CHEST_X + 0.5,
    bot.location.y + 0.5,
    COMPACTOR_CHEST_Z + 0.5
  )
  bot.wait_ticks 3

  # Open chest and deposit carrots + poisonous potatoes
  bot.open_container_handle do |handle|
    carrot_count = handle.count_in_player("carrot")
    handle.deposit("carrot", carrot_count) if carrot_count > 0

    poison_count = handle.count_in_player("poisonous_potato")
    handle.deposit("poisonous_potato", poison_count) if poison_count > 0

    potato_count = handle.count_in_player("potato")
    handle.deposit("potato", potato_count) if potato_count > 0
  end

  # Container is fully closed here — safe to pick from player inventory
  bot.wait_ticks 3

  # Hit the furnace with a stick to trigger compaction
  bot.inventory.pick! "stick"
  bot.look_at Rosegold::Vec3d.new(
    COMPACTOR_FURNACE_X + 0.5,
    bot.location.y + 0.5,
    COMPACTOR_FURNACE_Z + 0.5
  )
  bot.wait_ticks 2
  bot.attack
  bot.wait_ticks 3

  # Re-equip the Fortune III tool
  equip_fortune_tool!(bot)
  log "Compact done"
end

# =============================================================================
# FARM A SINGLE ROW
#
# The bot walks along `walk_x` and looks sideways to harvest crops at
# `harvest_x` (the adjacent row). This way:
#
#   - Items that pop TOWARD the bot land on the cleared walk path → picked up ✓
#   - Items that pop AWAY land on the next row → swept up on the next pass ✓
#   - Items that pop forward/backward → picked up as the bot walks through ✓
#
# When walk_x == harvest_x (first row), it harvests the row it stands on.
#
# dir=true  → walking north (toward Z_NORTH)
# dir=false → walking south (toward Z_SOUTH)
# =============================================================================

def farm_row!(bot : Rosegold::Bot, walk_x : Int32, harvest_x : Int32, dir : Bool)
  start_z = dir ? Z_SOUTH : Z_NORTH
  end_z   = dir ? Z_NORTH : Z_SOUTH
  step    = dir ? -1 : 1

  z = start_z
  while (dir ? z >= end_z : z <= end_z) && bot.connected?
    # Walk to this block on the cleared row
    begin
      bot.move_to(walk_x, z)
    rescue Rosegold::Physics::MovementStuck
      log "Stuck at x=#{walk_x} z=#{z} — advancing"
    end

    # Look at the crop in the harvest row and right-click to harvest it
    bot.look_at Rosegold::Vec3d.new(
      harvest_x + 0.5,
      bot.location.y,  # ground level where crops are
      z + 0.5
    )
    bot.use_hand

    # Wait for items to pop out and be picked up
    bot.wait_ticks(HARVEST_WAIT_TICKS)

    z += step
  end
end

# Walk a row without harvesting — just sweep up items on the ground.
def sweep_row!(bot : Rosegold::Bot, row_x : Int32, dir : Bool)
  start_z = dir ? Z_SOUTH : Z_NORTH
  end_z   = dir ? Z_NORTH : Z_SOUTH
  step    = dir ? -1 : 1

  z = start_z
  while (dir ? z >= end_z : z <= end_z) && bot.connected?
    begin
      bot.move_to(row_x, z)
    rescue Rosegold::Physics::MovementStuck
      log "Stuck sweeping at x=#{row_x} z=#{z} — advancing"
    end
    z += step
  end
end

# =============================================================================
# MAIN FARM LOOP
#
# The bot harvests each row by walking 2 rows BEHIND the harvest row.
# This gives items 2 full cleared rows to land on, maximizing pickup.
#
#   Row X_WEST  : walk on X_WEST, harvest X_WEST (offset 0, first row)
#   Row X_WEST+1: walk on X_WEST (cleared), harvest X_WEST+1 (offset 1)
#   Row X_WEST+2: walk on X_WEST (cleared), harvest X_WEST+2 (offset 2)
#   Row X_WEST+3: walk on X_WEST+1 (cleared), harvest X_WEST+3 (offset 2)
#   ...
#   Row X_EAST  : walk on X_EAST-2 (cleared), harvest X_EAST
#   Final sweep : walk X_EAST-1 then X_EAST to pick up remaining items
# =============================================================================

HARVEST_OFFSET = 2 # Walk this many rows behind the harvest row

def farm!(bot : Rosegold::Bot) : Int32
  row_x = bot.x.floor.to_i.clamp(X_WEST, X_EAST)

  if row_x != X_WEST
    log "Resuming at row #{row_x - X_WEST}/#{X_EAST - X_WEST} (x=#{row_x})"
  end

  # Infer starting direction from current Z position
  dir             = bot.z.floor.to_i >= (Z_NORTH + Z_SOUTH) // 2
  compact_counter = 0
  start_time      = Time.utc

  while row_x <= X_EAST && bot.connected?
    rows_left = X_EAST - row_x + 1
    secs      = (rows_left * TIME_PER_ROW).to_i
    log "#{rows_left} rows left (~#{secs // 60}m #{secs % 60}s)"

    # Walk on a cleared row N rows behind, clamped to X_WEST for first rows
    walk_x = {row_x - HARVEST_OFFSET, X_WEST}.max
    bot.move_to(walk_x, dir ? Z_SOUTH : Z_NORTH)
    farm_row!(bot, walk_x, row_x, dir)

    row_x           += 1
    dir              = !dir
    compact_counter += 1

    if compact_counter >= ROWS_PER_COMPACT
      compact!(bot)
      compact_counter = 0
    end
  end

  # Final sweep: walk the last few rows to collect items that popped east
  if bot.connected?
    log "Final sweep to collect remaining items..."
    (1..HARVEST_OFFSET).each do |offset|
      sweep_x = X_EAST - HARVEST_OFFSET + offset
      next if sweep_x < X_WEST || sweep_x > X_EAST
      bot.move_to(sweep_x, dir ? Z_SOUTH : Z_NORTH)
      sweep_row!(bot, sweep_x, dir)
      dir = !dir
    end
    compact!(bot)
  end

  elapsed = (Time.utc - start_time).total_seconds.to_i
  log "Farm complete in #{elapsed // 60}m #{elapsed % 60}s"
  elapsed
end

# =============================================================================
# STOP COMMAND
#
# Only accepts "!stop" from your NL group chat. On CivMC, NL group messages
# appear as: [GroupName] PlayerName: message
# So we check that the message contains both "[Ila'Kyavul]" and "!stop".
# =============================================================================

# NL group whose members are allowed to stop the bot
STOP_GROUP = "[#{DISCORD_GROUP}]"

# Flag — when true, the reconnect loop exits instead of retrying
class BotState
  class_property? stopped : Bool = false
end

def register_stop_listener(bot : Rosegold::Bot)
  bot.on Rosegold::Clientbound::SystemChatMessage do |msg|
    text = msg.message.to_s
    if text.includes?(STOP_GROUP) && text.includes?("!stop")
      log "!stop from #{STOP_GROUP} — shutting down"
      BotState.stopped = true
      begin
        bot.chat "/logout"
        sleep 2.seconds
      rescue
      end
      bot.disconnect("!stop command received")
    end
  end
end

# =============================================================================
# ENTRY POINT
# =============================================================================

spectate_server = Rosegold::SpectateServer.new(SPECTATE_HOST, SPECTATE_PORT)
spectate_server.start
log "SpectateServer listening on #{SPECTATE_HOST}:#{SPECTATE_PORT}"

# Force protocol to 1.21.11 (774) so the SpectateServer is compatible
# with 1.21.11 clients. Remove this line to auto-detect from the server.
Rosegold::Client.protocol_version = 774_u32

retry_delay = INITIAL_RETRY_DELAY

loop do
  break if BotState.stopped?

  begin
    client = Rosegold::Client.new SERVER_HOST
    spectate_server.attach_client client
    bot = Rosegold::Bot.new(client)
    bot.join_game
    sleep 3.seconds
    retry_delay = INITIAL_RETRY_DELAY
    log "Connected as #{bot.username}"

    x = bot.x.floor.to_i
    z = bot.z.floor.to_i
    unless (X_WEST..X_EAST).includes?(x) && (Z_NORTH..Z_SOUTH).includes?(z)
      log "ERROR: Bot at (#{x}, #{z}) is outside farm bounds."
      log "Move inside the farm (x #{X_WEST}–#{X_EAST}, z #{Z_NORTH}–#{Z_SOUTH}) and restart."
      break
    end

    validate_inventory!(bot)
    equip_fortune_tool!(bot)
    register_stop_listener(bot)

    elapsed = farm!(bot)

    break if BotState.stopped? # !stop was received during farming

    if bot.connected?
      bot.chat "/g #{DISCORD_GROUP} #{FARM_NAME} done in #{elapsed // 60}m #{elapsed % 60}s. Ready in #{REGROW_HOURS}h."
      sleep 2.seconds
      bot.chat "/logout"
      sleep 2.seconds
      bot.disconnect("Farm complete")
      break # finished cleanly — don't reconnect
    end

    log "Disconnected mid-farm, retrying in #{retry_delay.total_seconds.to_i}s..."
    sleep retry_delay
    retry_delay = {retry_delay * 2, MAX_RETRY_DELAY}.min

  rescue e
    break if BotState.stopped?
    log "Error: #{e.message}, retrying in #{retry_delay.total_seconds.to_i}s..."
    sleep retry_delay
    retry_delay = {retry_delay * 2, MAX_RETRY_DELAY}.min
  end
end

log BotState.stopped? ? "Bot stopped by !stop command." : "Bot finished."