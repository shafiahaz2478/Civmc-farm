require "rosegold"

class BonemealMonitorBot
  # --- CONFIGURATION ---
  CHANNEL   = "shafiahaz2478"
  KILL_WORD = "stop"

  # The four chest positions (vertical stack, same X/Z, Y 35–38)
  CHEST_POSITIONS = [
    Rosegold::Vec3i.new(6240, 35, -2802),
    Rosegold::Vec3i.new(6240, 36, -2802),
    Rosegold::Vec3i.new(6240, 37, -2802),
    Rosegold::Vec3i.new(6240, 38, -2802),
  ]

  @bot : Rosegold::Bot

  def initialize(@bot : Rosegold::Bot)
    setup_killswitch
  end

  def setup_killswitch
    @bot.on Rosegold::Clientbound::SystemChatMessage do |event|
      message = event.message.to_s.downcase

      if message.includes?("[#{CHANNEL.downcase}]") && message.ends_with?(": #{KILL_WORD.downcase}")
        puts "\n[🚨] Kill switch activated via group chat! Logging out..."
        @bot.chat("/logout")
        exit(0)
      end
    end

    @bot.on Rosegold::Clientbound::PlayerChatMessage do |event|
      if event.message.to_s.downcase == KILL_WORD.downcase
        puts "\n[🚨] Kill switch activated via standard player chat! Logging out..."
        @bot.chat("/logout")
        exit(0)
      end
    end
  end

  def check_chests_and_report
    total_bonemeal = 0

    CHEST_POSITIONS.each_with_index do |chest_pos, index|
      puts "Scanning chest #{index + 1}/#{CHEST_POSITIONS.size} at (#{chest_pos.x}, #{chest_pos.y}, #{chest_pos.z})..."

      begin
        # Look at the center of the chest block
        target = Rosegold::Vec3d.new(chest_pos.x + 0.5, chest_pos.y + 0.5, chest_pos.z + 0.5)
        @bot.look_at(target)
        @bot.wait_ticks(5)

        @bot.open_container_handle do |chest|
          count = chest.count_in_container("bone_meal")
          total_bonemeal += count
          puts "  Chest #{index + 1}: #{count} Bone Meal"
        end
      rescue ex
        puts "  Chest #{index + 1} failed: #{ex.message}"
      end

      @bot.wait_ticks(10)
    end

    report_msg = "Bonemeal stock: #{total_bonemeal} Bone Meal across #{CHEST_POSITIONS.size} chests"
    puts "Sending report: #{report_msg}"
    @bot.chat("/g #{CHANNEL} #{report_msg}")
  end

  def start
    puts "Bonemeal monitor started."
    puts "Watching #{CHEST_POSITIONS.size} chests. AFK scanning for bone_meal."
    puts "Sending initial chest report..."

    check_chests_and_report

    loop do
      # Check every 5 minutes (20 ticks/sec * 60 sec * 5 min = 6000 ticks)
      @bot.wait_ticks(6000)

      check_chests_and_report
    end
  end
end

# --- Script Execution ---
puts "Connecting to server..."
bot = Rosegold::Bot.join_game("play.civmc.net")
puts "Connected! Waiting for physics and chunks to settle..."
bot.wait_ticks(40)

monitor = BonemealMonitorBot.new(bot)
monitor.start
