require "rosegold"

# Harvests a melon farm in two sides (west/east of a 4-wide center row), going
# south→north, breaking with an axe and switching tools as durability runs out.
# Periodically deposits melon in a chest and lights a stick-fired furnace.
# Adapted from arthirob's MelonCompact.js (v1.4).

SERVER_HOST   = ENV.fetch "SERVER_HOST", "play.civmc.net"
SPECTATE_HOST = ENV.fetch "SPECTATE_HOST", "0.0.0.0"
SPECTATE_PORT = ENV.fetch("SPECTATE_PORT", "25566").to_i

INITIAL_RETRY_DELAY = 5.seconds
MAX_RETRY_DELAY     = 5.minutes

X_EAST           =  8508
X_WEST           =  8249
Z_NORTH          = -2736
Z_SOUTH          = -2557
CENTER_ROW       =  8377
CENTER_ROW_WIDTH =     4
PLOT_HEIGHT      =     4 # Each plot covers 4 z-rows; cursor advances by this each iteration.

X_FRONT_COMPACTOR   =  8377
Z_FRONT_COMPACTOR   = -2644
X_CHEST_COMPACTOR   =  8379
Z_CHEST_COMPACTOR   = -2646
X_FURNACE_COMPACTOR =  8379
Z_FURNACE_COMPACTOR = -2645
Y_COMPACTOR         =   143

COMPACT_EVERY_PLOT = 6
LAG_TICKS          = 6

DISCORD_GROUP = "mtafarm"
FARM_NAME     = "Melon farm near Maius(gs melon farm)"
REGROW_HOURS  = 27

PITCH_VALUE       = 10.0_f32  # nominal harvesting pitch
PITCH_STUCK       = 28.0_f32  # steeper pitch to chew through a blocking melon
BREAK_TIME        =        2  # ticks per melon break (with haste II)
SPEED_REDRINK_GAP = 5.seconds # min time between speed-pot attempts

class MelonHarvester
  getter bot : Rosegold::Bot

  @dir : Int32 = 0  # 0 = going west (yaw 90), 1 = going east (yaw 270)
  @side : Int32 = 0 # 0 = west side, 1 = east side
  @plot_count : Int32 = 0
  @current_plot : Int32 = 0
  @start_time : Time
  @speed_pot_available : Bool = true
  @last_speed_attempt : Time = Time.unix(0)

  def initialize(@bot : Rosegold::Bot)
    @start_time = Time.utc
  end

  def start
    cur_x = bot.x.floor.to_i
    cur_z = bot.z.floor.to_i
    unless (X_WEST..X_EAST).includes?(cur_x) && (Z_NORTH..Z_SOUTH).includes?(cur_z)
      Log.warn { "Not inside melon farm bounds (#{cur_x}, #{cur_z})" }
      return
    end
    unless cur_x == CENTER_ROW || cur_x == CENTER_ROW + CENTER_ROW_WIDTH - 1
      Log.info { "Not on the centerline (x=#{cur_x}); chopping back" }
      wake_up_and_recover
      cur_x = bot.x.floor.to_i
      cur_z = bot.z.floor.to_i
      unless cur_x == CENTER_ROW || cur_x == CENTER_ROW + CENTER_ROW_WIDTH - 1
        Log.warn { "Failed to recover to centerline (x=#{cur_x})" }
        return
      end
    end

    if cur_x == CENTER_ROW
      @side = 0
      @dir = 0
    else
      @side = 1
      @dir = 1
    end
    @current_plot = cur_z - (cur_z + 1) % PLOT_HEIGHT
    @plot_count = 0

    pick_axe
    disable_ctb
    bot.eat!
    harvest_main
    finish_farm
  end

  private def harvest_main
    while @side <= 1
      harvest_side
      @side += 1
      @current_plot = Z_SOUTH
      @dir = 1
    end
  end

  private def harvest_side
    while @current_plot > Z_NORTH
      harvest_plot
      if @plot_count >= COMPACT_EVERY_PLOT
        compact
        @plot_count = 0
      end
      @current_plot -= PLOT_HEIGHT
    end
  end

  private def harvest_plot
    harvest_line
    @dir = 1 - @dir
    harvest_line
    @dir = 1 - @dir
    @plot_count += 1
    bot.eat!
  end

  private def harvest_line
    go_front_line
    refresh_speed_if_needed
    pick_axe

    yaw = (90 + @dir * 180).to_f32
    walk_attacking_to(end_of_line_x, bot.z.floor.to_i, yaw)
  end

  # Walks to (target_x, z) on a fixed yaw while holding attack. The rosegold
  # tick loop continues digging the targeted block as the bot moves through it.
  # If movement stalls (Physics::MovementStuck), look steeply down and chew
  # through the blocker, then retry. A spawned fiber keeps re-equipping a fresh
  # axe so a tool break mid-traversal doesn't strand us with bare fists.
  private def walk_attacking_to(target_x : Int32, z : Int32, yaw : Float32)
    going_east = target_x > bot.x.floor.to_i

    loop do
      x = bot.x.floor.to_i
      break if going_east ? x >= target_x : x <= target_x

      bot.look = Rosegold::Look.new(yaw, PITCH_VALUE)

      keep_picking = true
      spawn do
        while keep_picking && bot.connected?
          bot.wait_ticks 4
          pick_axe rescue nil
        end
      end

      begin
        bot.start_digging
        bot.move_to(target_x, z, stuck_timeout_ticks: 30)
        bot.stop_digging
      rescue Rosegold::Physics::MovementStuck
        bot.stop_digging
        bot.look = Rosegold::Look.new(yaw, PITCH_STUCK)
        bot.dig BREAK_TIME * 4
        bot.look = Rosegold::Look.new(yaw, PITCH_VALUE)
      ensure
        keep_picking = false
      end
    end
  end

  # Recovery after an unexpected reconnect: chop back to the centerline so the
  # main loop can pick up where it left off. Jumps first in case a melon grew at
  # head height; figures out which side of the farm we landed on, faces the
  # nearer centerline column (CENTER_ROW or CENTER_ROW + 3), and walks while
  # attacking.
  private def wake_up_and_recover
    bot.start_jump
    bot.wait_ticks 5

    pick_axe rescue Log.warn { "No usable axe in inventory; recovery will be slow" }

    cur_x = bot.x.floor.to_i
    z = bot.z.floor.to_i
    target_x =
      if cur_x < CENTER_ROW
        CENTER_ROW
      elsif cur_x > CENTER_ROW + CENTER_ROW_WIDTH - 1
        CENTER_ROW + CENTER_ROW_WIDTH - 1
      elsif cur_x - CENTER_ROW <= 1
        CENTER_ROW
      else
        CENTER_ROW + CENTER_ROW_WIDTH - 1
      end
    yaw = cur_x < target_x ? 270.0_f32 : 90.0_f32

    walk_attacking_to(target_x, z, yaw)
  end

  # The far x of a line for a given direction. Each side has a center boundary
  # (the 4-wide center row) and an outer boundary (xWest/xEast).
  private def line_x_for(dir : Int32) : Int32
    case {@side, dir}
    when {0, 0} then X_WEST
    when {0, 1} then CENTER_ROW
    when {1, 0} then CENTER_ROW + CENTER_ROW_WIDTH - 1
    when {1, 1} then X_EAST
    else             bot.x.floor.to_i
    end
  end

  private def end_of_line_x : Int32
    line_x_for(@dir)
  end

  private def go_front_line
    # The line's start is the end-of-line for the opposite direction.
    obj_x = line_x_for(1 - @dir)
    # When side and dir agree (both 0 or both 1), z offset is -1; otherwise -2.
    obj_z = @current_plot + (@side == @dir ? -1 : -2)
    bot.move_to(obj_x, obj_z)
    bot.stop_digging
    bot.wait_tick
  end

  private def pick_axe
    found = bot.inventory.pick("netherite_axe") || bot.inventory.pick("diamond_axe")
    raise "No more usable axes in inventory" unless found
  end

  private def disable_ctb
    spawn do
      bot.run_command_with_confirmation(
        "/ctb",
        "Bypass mode has been disabled.",
        3,
        "Bypass mode has been enabled. You will be able to break reinforced blocks if you are on the group."
      )
    end
  end

  private def refresh_speed_if_needed
    return unless @speed_pot_available
    return if bot.speed_level > 0
    return if (Time.utc - @last_speed_attempt) < SPEED_REDRINK_GAP

    @last_speed_attempt = Time.utc
    unless bot.inventory.pick("potion")
      Log.info { "Out of speed potions" }
      @speed_pot_available = false
      return
    end

    bot.start_using_hand
    timeout = Time.utc + 4.seconds
    while bot.speed_level <= 0 && Time.utc < timeout
      bot.wait_tick
    end
    bot.stop_using_hand
    pick_axe
  end

  private def compact
    bot.move_to(X_FRONT_COMPACTOR, Z_FRONT_COMPACTOR)
    chest = Rosegold::Vec3d.new(X_CHEST_COMPACTOR + 0.5, Y_COMPACTOR + 0.5, Z_CHEST_COMPACTOR + 0.5)
    bot.look_at chest

    bot.open_container do
      bot.inventory.deposit_at_least(2048, "melon")
    end
    bot.wait_ticks LAG_TICKS

    bot.inventory.pick("stick") || raise "No stick in inventory for furnace ignition"
    furnace = Rosegold::Vec3d.new(X_FURNACE_COMPACTOR + 0.5, Y_COMPACTOR + 0.5, Z_FURNACE_COMPACTOR + 0.5)
    bot.look_at furnace
    bot.attack
    bot.wait_ticks LAG_TICKS

    pick_axe
  end

  private def finish_farm
    secs = (Time.utc - @start_time).total_seconds.to_i
    minutes, seconds = secs.divmod(60)
    bot.chat "/g #{DISCORD_GROUP} #{FARM_NAME} is finished to harvest in #{minutes} minutes and #{seconds} seconds. It'll be ready again in #{REGROW_HOURS} hours. Now logging out"
    bot.chat "/logout"
  end
end

spectate_server = Rosegold::SpectateServer.new(SPECTATE_HOST, SPECTATE_PORT)
spectate_server.start

retry_delay = INITIAL_RETRY_DELAY

loop do
  begin
    client = Rosegold::Client.new SERVER_HOST
    spectate_server.attach_client client
    bot = Rosegold::Bot.new(client)
    bot.join_game
    sleep 3.seconds
    retry_delay = INITIAL_RETRY_DELAY

    Log.info { "Connected, starting melon farm" }
    MelonHarvester.new(bot).start
    break
  rescue e
    Log.error { "Run failed: #{e.message}; retrying in #{retry_delay.total_seconds}s" }
    sleep retry_delay
    retry_delay = [retry_delay * 2, MAX_RETRY_DELAY].min
  end
end