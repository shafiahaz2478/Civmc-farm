require "rosegold"

class ChestMonitorBot
  # --- CONFIGURATION ---
  CHANNEL = "shafiahaz2478"    
  KILL_WORD = "stop"           

  @bot : Rosegold::Bot
  @chest_pos : Rosegold::Vec3i

  def initialize(bot : Rosegold::Bot)
    @bot = bot
    
    # Calculate the chest position directly above the bot.
    @chest_pos = Rosegold::Vec3i.new(
      @bot.feet.x.floor.to_i,
      @bot.feet.y.floor.to_i + 4, 
      @bot.feet.z.floor.to_i
    )

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

  def check_chest_and_report
    # BYPASS FIX: Look directly up (-90 pitch) instead of using the bugged look_at vector method
    @bot.pitch = -90.0
    @bot.yaw = 0.0
    @bot.wait_ticks(10)

    report_msg = ""

    # Try to open the chest
    begin
      @bot.place_block_against(@chest_pos, :bottom) 
      @bot.wait_ticks(10)

      @bot.open_container_handle do |chest|
        # Check for the specific flowers
        alliums = chest.count_in_container("allium")
        azure_bluets = chest.count_in_container("azure_bluet")
        
        report_msg = "Chest contains: #{alliums} Allium, #{azure_bluets} Azure Bluets"
      end
    rescue ex
      report_msg = "Error: I cannot reach or open the chest above me."
      puts "Chest interaction failed: #{ex.message}"
    end

    @bot.wait_ticks(10) 

    # Send the report to the designated channel
    puts "Sending report: #{report_msg}"
    @bot.chat("/g #{CHANNEL} #{report_msg}")
  end

  def start
    puts "Monitor started. Chest target is X:#{@chest_pos.x}, Y:#{@chest_pos.y}, Z:#{@chest_pos.z}"
    puts "Sending initial chest report..."
    
    check_chest_and_report

    loop do
      # 20 game ticks per second * 60 seconds * 5 minutes = 6000 ticks.
      @bot.wait_ticks(6000) 
      
      check_chest_and_report
    end
  end
end

# --- Script Execution ---
puts "Connecting to server..."
bot = Rosegold::Bot.join_game("play.civmc.net") 
puts "Connected! Waiting for physics and chunks to settle..."
bot.wait_ticks(40)

monitor = ChestMonitorBot.new(bot)
monitor.start