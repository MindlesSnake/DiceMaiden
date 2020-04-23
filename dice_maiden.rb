# Dice bot for Discord
# Original Author: Humblemonk
# Version: 4.0.6
# Copyright (c) 2017. All rights reserved.
# Forked By: Nelson "MindlesSnake" Campos
# Version: 1.0.0
# Copyright (c) 2020. All rights reserved.
# !/usr/bin/ruby

require 'discordrb'
require 'dicebag'
require 'dotenv'
require 'rest-client'
require 'sqlite3'

# Returns an input string after it's been put through the aliases
def alias_input_pass(input)
  # Each entry is formatted [/Alias match regex/, "Alias Name", /gsub replacement regex/, "replace with string"]
  alias_input_map = [
      [/\b\d+WoD\d+\b/i, "WoD", /\b(\d+)WoD(\d+)\b/i, "\\1d10 f1 t\\2"], # World of Darkness 4th edition (note: explosions are left off for now)
      [/\b\d+dF\b/i, "Fudge", /\b(\d+)dF\b/i, "\\1d3 f1 t3"], # Fate fudge dice
      [/\b\d+wh\d+\+/i, "Warhammer", /\b(\d+)wh(\d+)\+/i, "\\1d6 t\\2"], # Warhammer (AoS/40k)
      [/\bdd\d\d\b/i, "Double Digit", /\bdd(\d)(\d)\b/i, "(1d\\1 * 10) + 1d\\2"], # Rolling one dice for each digit
  ]

  @alias_types = []
  new_input = input

  # Run through all aliases and record which ones we use
  for alias_entry in alias_input_map do
    if input.match?(alias_entry[0])
      @alias_types.append(alias_entry[1])
      new_input.gsub!(alias_entry[2], alias_entry[3])
    end
  end

  return new_input
end

# Returns dice string after it's been put through the aliases
def alias_output_pass(roll_tally)
  # Each entry is formatted "Alias Name":[[]/gsub replacement regex/, "replace with string", etc]
  # Not all aliases will have an output hash
  alias_output_hash = {
      "Fudge" => [[/\b1\b/, "-"], [/\b2\b/, " "], [/\b3\b/, "+"]]
  }

  new_tally = roll_tally

  for alias_type in @alias_types do
    if alias_output_hash.has_key?(alias_type)
      alias_output = alias_output_hash[alias_type]
      for replacement in alias_output do
        new_tally.gsub!(replacement[0], replacement[1])
      end
    end
  end

  return new_tally
end

def check_user_or_nick(event)
  if event.user.nick != nil
    @user = event.user.nick
  else
    @user = event.user.name
  end
end

def check_comment
  if @input.include?('!')
    @comment = @input.partition('!').last.lstrip
    if @comment.include? 'unsort'
      @do_tally_shuffle = 1
    end
    @roll = @input[/(^.*)!/]
    @roll.slice! @comment
    @roll.slice! '!'
  end
end

def check_roll(event)
  dice_requests = @roll.scan(/\d+d\d+/i)

  for dice_request in dice_requests
    @special_check = dice_request.scan(/d(\d+)/i).first.join.to_i
    @dice_check = dice_request.scan(/d(\d+)/i).first.join.to_i

    if @dice_check < 2
      event.respond 'Please roll a dice value 2 or greater'
      return true
    end
    if @dice_check > 100
      event.respond 'Please roll dice up to d100'
      return true
    end
    # Check for too large of dice pools
    @dice_check = dice_request.scan(/(\d+)d/i).first.join.to_i
    if @dice_check > 500
      event.respond 'Please keep the dice pool below 500'
      return true
    end
  end
end

def check_wrath
  if (@special_check == 6) && (@wng == true) && ((@comment.include? 'soak') || (@comment.include? 'exempt') || (@comment.include? 'dmg'))
  elsif (@special_check == 6) && (@wng == true)
    @roll = "#{@dice_check - 1}d6"
    wstr = '(Wrath Dice) 1d6'
    wroll = DiceBag::Roll.new(wstr)
    @wresult = wroll.result
    @wresult_convert = @wresult.to_s
    @wrath_value = @wresult_convert.scan(/\d+/).first
    true
  end
end

# Takes raw input and returns a reverse polish notation queue of operators and Integers
def convert_input_to_RPN_queue(event, input)
  split_input = input.scan(/\b(?:\d+[d]\d+(?:\s?[a-z]+\d+)*)|[\+\-\*\/]|(?:\b\d+\b)|[\(\)]/i)# This is the tokenization string for our input

  # change to read left to right order
  input_queue = []
  while split_input.length > 0
    input_queue.push(split_input.pop)
  end

  operator_priority = {
      "+" => 1,
      "-" => 1,
      "*" => 2,
      "/" => 2
  }

  output_queue = []
  operator_stack = []

  # Use the shunting yard algorithm to get our order of operations right
  while input_queue.length > 0
    input_queue_peek = input_queue.last

    if input_queue_peek.match?(/\b\d+\b/)# If constant in string form
      output_queue.prepend(Integer(input_queue.pop))

    elsif input_queue_peek.match?(/\b\d+[d]\w+/i)# If dice roll
      output_queue.prepend(process_roll_token(event, input_queue.pop))

    elsif input_queue_peek.match?(/[\+\-\*\/]/)
      # If the peeked operator is not higher priority than the top of the stack, pop the stack operator down
      if operator_stack.length == 0 || operator_stack.last == "(" || operator_priority[input_queue_peek] > operator_priority[operator_stack.last]
        operator_stack.push(input_queue.pop)
      else
        output_queue.prepend(operator_stack.pop)
        operator_stack.push(input_queue.pop)
      end

    elsif input_queue_peek == "("
      operator_stack.push( input_queue.pop )

    elsif input_queue_peek == ")"
      while operator_stack.last != '('
        output_queue.prepend(operator_stack.pop)

        if operator_stack.length == 0
          raise "Extra ')' found!"
        end
      end
      operator_stack.pop # Dispose of the closed "("
      input_queue.pop # Dispose of the closing ")"
    else
      raise "Invalid token! (#{input_queue_peek})"
    end
  end

  while operator_stack.length > 0
    if operator_stack.last == '('
      raise "Extra '(' found!"
    end
    output_queue.prepend(operator_stack.pop)
  end

  return output_queue
end

# Process a stack of tokens in reverse polish notation completely and return the result
def process_RPN_token_queue(input_queue)
  output_stack = []

  while input_queue.length > 0
    input_queue_peek = input_queue.last

    if input_queue_peek.is_a?(Integer)
      output_stack.push(input_queue.pop)

    else # Must be an operator
      if output_stack.length < 2
        raise input_queue.pop + " is not between two numbers!"
      end

      operator = input_queue.pop
      operand_B = output_stack.pop
      operand_A = output_stack.pop
      output_stack.push(process_operator_token(operator, operand_A, operand_B))
    end
  end

  if output_stack.length > 1
    raise "Extra numbers detected!"
  end

  return output_stack[0]# There can be only one!
end

# Takes a operator token (e.g. '+') and return the result of the operation on the given operands
def process_operator_token(token, operand_A, operand_B)
  if token == '+'
    return operand_A + operand_B
  elsif token == '-'
    return operand_A - operand_B
  elsif token == '*'
    return operand_A * operand_B
  elsif token == '/'
    if operand_B == 0
      raise 'Tried to divide by zero!'
    end
    return operand_A / operand_B
  else
    raise "Invalid Operator: #{token}"
  end
end

# Takes a roll token, appends the roll results, and returns the total
def process_roll_token(event, token)
  begin
    dice_roll = DiceBag::Roll.new(token + @dice_modifiers)
      # Rescue on bad dice roll syntax
  rescue Exception => error
    raise 'Roller encountered error with "' + token + @dice_modifiers + '": ' + error.message
  end
  token_total = dice_roll.result.total
  # Parse the roll and grab the total tally
  parse_roll = dice_roll.tree
  parsed = parse_roll.inspect
  roll_tally = parsed.scan(/tally=\[.*?\]/)
  roll_tally = String(roll_tally)
  roll_tally.gsub!(/\[*("tally=)|\"\]|\"/, '')
  if @do_tally_shuffle == 1
    roll_tally.gsub!("[",'')
    roll_tally_array = roll_tally.split(', ').map(&:to_i)
    roll_tally = roll_tally_array.shuffle!
    roll_tally = String(roll_tally)
  end
  @tally += roll_tally

  return token_total
end

def do_roll(event)
  roll_result = nil
  @tally = ""

  begin
    roll_result = process_RPN_token_queue(convert_input_to_RPN_queue(event, @roll))
  rescue RuntimeError => error
    event.respond 'Error: ' + error.message
    return true
  end

  @dice_result = "Result: #{roll_result}"
end

def log_roll(event)
  @server = event.server.name
  @time = Time.now.getutc
  unless @roll_set.nil?
    File.open('dice_rolls.log','a') { |f| f.puts "#{@time} Shard: #{@shard} | #{@server}| #{@user} Rolls:\n #{@roll_set_results}" }
  else
    File.open('dice_rolls.log', 'a') { |f| f.puts "#{@time} Shard: #{@shard} |#{@server}| #{@user} Roll: #{@tally} #{@dice_result}" }
  end
end

def check_fury(event)
  if (@special_check == 10) && (@tally.include? '10') && (@dh == true)
    event.respond '`Righteous Fury Activated!` Purge the Heretic!'
  end
end

def check_icons
  @fours = @tally.scan(/4/).count
  @fives = @tally.scan(/5/).count
  @exalted_icons = @tally.scan(/6/).count
  @exalted_icons += 1 if @wresult_convert.include? '6'
  if (@wresult_convert.include? '4') || (@wresult_convert.include? '5')
    @wrath_icon = 1
  else
    @wrath_icon = 0
  end
  @exalted_total = @exalted_icons * 2
  @icons = @fours + @fives + @wrath_icon
end

def check_dn(dnum)
  icon_total = @icons + @exalted_total
  @test_status = if icon_total >= dnum
                   '**TEST PASSED!**'
                 else
                   '**TEST FAILED!**'
  end
end

def check_universal_modifiers
  # Read universal dice modifiers
  @dice_modifiers = @roll.scan(/(?:\s(?:\b[a-z]+\d+\b))+$/i).first # Grab all options and whitespace at end of input and separated
  if @dice_modifiers == nil
    @dice_modifiers = ""
  else
    @roll = @roll[0..-@dice_modifiers.length]
  end
end

def event_no_comment_wrath(event, dnum)
  if @roll == '0d6'
    event.respond "#{@user} Roll: Wrath: `#{@wrath_value}`"
  else
    check_icons
    if dnum.to_s.empty? || dnum.to_s.nil?
    else
      check_dn(dnum)
    end
    event.respond "#{@user} Roll: `#{@tally}` Wrath: `#{@wrath_value}` | #{@test_status} TOTAL - Icons: `#{@icons}` Exalted Icons: `#{@exalted_icons} (Value:#{@exalted_total})`"
    if @wresult_convert.include? '6'
      event.respond 'Combat critical hit and one point of Glory!'
    elsif @wresult_convert.include? '1'
      event.respond 'Complication!'
    end
  end
end

def event_comment_wrath(event, dnum)
  if @roll == '0d6'
    event.respond "#{@user} Roll Wrath: `#{@wrath_value}`"
    event.respond "Roll Reason: `#{@comment}`"
  else
    check_icons
    if dnum.to_s.empty? || dnum.to_s.nil?
    else
      check_dn(dnum)
    end
    event.respond "#{@user} Roll: `#{@tally}` Wrath: `#{@wrath_value}` | #{@test_status} TOTAL - Icons: `#{@icons}` Exalted Icons: `#{@exalted_icons} (Value:#{@exalted_total})`"
    event.respond "Roll Reason: `#{@comment}`"
    if @wresult_convert.include? '6'
      event.respond 'Combat critical hit and one point of Glory!'
    elsif @wresult_convert.include? '1'
      event.respond 'Complication!'
    end
  end
end

def check_donate(event)
  if @roll.include? 'donate'
    event.respond "\n Care to support the bot? You can donate via Patreon https://www.patreon.com/dicemaiden \n You can also do a one time donation via donate bot located here https://donatebot.io/checkout/534632036569448458"
  end
end

def check_help(event)
  if @roll.include? 'help'
    event.respond "``` Synopsis:\n\t!roll xdx [OPTIONS]\n\n\tDescription:\n\n\t\txdx : Denotes how many dice to roll and how many sides the dice have.\n\n\tThe following options are available:\n\n\t\t+ - / * : Static modifier\n\n\t\te# : The explode value.\n\n\t\tk# : How many dice to keep out of the roll, keeping highest value.\n\n\t\tr# : Reroll value.\n\n\t\tt# : Target number for a success.\n\n\t\tf# : Target number for a failure.\n\n\t\t! : Any text after ! will be a comment.\n\n !roll donate : Care to support the bot? Get donation information here. Thanks!\n\n Find more commands at https://github.com/Humblemonk/DiceMaiden\n```"
  end
end

def check_purge(event)
  if @roll.include? 'purge'
    @roll.slice! 'purge'
    amount = @input.to_i
    if (amount < 2) || (amount > 100)
      event.respond 'Amount must be between 2-100'
      return false
    end
    if event.user.defined_permission?(:manage_messages) == true || event.user.defined_permission?(:administrator) == true || event.user.permission?(:manage_messages, event.channel) == true
      event.channel.prune(amount)
    else
      event.respond "#{@user} does not have permissions for this command"
    end
  end
end

def check_bot_info(event)
  if @roll.include? 'bot-info'
    servers = $db.execute "select sum(server_count) from shard_stats;"
    event.respond "| Dice Maiden | - #{servers.join.to_i} active servers"
  end
end
Dotenv.load
@total_shards = ENV['SHARD'].to_i
# Add API token
@bot = Discordrb::Bot.new token: ENV['TOKEN'], num_shards: @total_shards, shard_id: ARGV[0].to_i, ignore_bots: true, fancy_log: true
@shard = ARGV[0].to_i
@logging = ARGV[1].to_i

# open connection to sqlite db and set timeout to 10s if the database is busy
$db = SQLite3::Database.new "main.db"
$db.busy_timeout=(10000)

# Check for command
@bot.message(start_with: /^(!roll)/i) do |event|
  begin
    @input = alias_input_pass(event.content) # Do alias pass as soon as we get the message
    @simple_output = false
    @wng = false
    @dh = false

    # check for wrath and glory game mode for roll
    if @input.match(/!roll\s(wng)\s/i)
      @wng = true
      @input.sub!("wng","")
    end

    # check for Dark heresy game mode for roll
    if @input.match(/!roll\s(dh)\s/i)
      @dh = true
      @input.sub!("dh","")
    end

    if @input.match(/!roll\s(s)\s/i)
      @simple_output = true
      @input.sub!("s","")
    end

    @roll_set = nil
    @roll_set = @input.scan(/!roll\s(\d+)\s/i).first.join.to_i if @input.match(/!roll\s(\d+)\s/i)

    unless @roll_set.nil?
      if (@roll_set <=1) || (@roll_set > 20)
        event.respond "Roll set must be between 2-20"
        next
      end
    end

    unless @roll_set.nil?
      @input.slice! /!roll/i
      @input.slice!(0..@roll_set.to_s.size)
    else
      @input.slice! /!roll/i
    end

    if @input =~ /^\s+d/
      roll_to_one = @input.lstrip
      roll_to_one.prepend("1")
      @input = roll_to_one
    end

    @roll = @input
    @comment = ''
    @test_status = ''
    @do_tally_shuffle = 0
    # check user
    check_user_or_nick(event)
    # check for comment
    check_comment
    # check for modifiers that should apply to everything
    check_universal_modifiers

    # Check for dn
    dnum = @input.scan(/dn\s?(\d+)/).first.join.to_i if @input.include?('dn')

    # Check for correct input
    if @roll.match?(/\dd\d/i)
      next if check_roll(event) == true

      # Check for wrath roll
      check_wrath
      # Grab dice roll, create roll, grab results
      unless @roll_set.nil?
        @roll_set_results = ''
        roll_count= 0
        error_encountered = false
        while roll_count < @roll_set.to_i
          if do_roll(event) == true
            error_encountered = true
            break
          end
          @tally = alias_output_pass(@tally)
          @roll_set_results << "`#{@tally}` #{@dice_result}\n"
          roll_count += 1
        end
        next if error_encountered

        if @logging == "debug"
          log_roll(event)
        end
        if @comment.to_s.empty? || @comment.to_s.nil?
          event.respond "#{@user} Rolls:\n#{@roll_set_results}"
        else
          event.respond "#{@user} Rolls:\n#{@roll_set_results} Reason: `#{@comment}`"
        end
        next
      else
        next if do_roll(event) == true
      end

      # Output aliasing
      @tally = alias_output_pass(@tally)

      # Grab event user name, server name and timestamp for roll and log it
      if @logging == "debug"
        log_roll(event)
      end
      # Print dice result to Discord channel
      if @comment.to_s.empty? || @comment.to_s.nil?
        if check_wrath == true
          event_no_comment_wrath(event, dnum)
        else
          if @simple_output == true
            event.respond "#{@user} Roll #{@dice_result}"
            check_fury(event)
          else
            event.respond "#{@user} Roll: `#{@tally}` #{@dice_result}"
            check_fury(event)
          end
        end
      else
          if check_wrath == true
            event_comment_wrath(event, dnum)
          else
            if @simple_output == true
              event.respond "#{@user} Roll #{@dice_result} Reason: `#{@comment}`"
              check_fury(event)
            else
              event.respond "#{@user} Roll: `#{@tally}` #{@dice_result} Reason: `#{@comment}`"
              check_fury(event)
            end
          end
      end
    end
    check_donate(event)
    check_help(event)
    check_bot_info(event)
    next if check_purge(event) == false
  rescue StandardError => error ## The worst that should happen is that we catch the error and return its message.
    if(error.message == nil )
      error.message = "NIL MESSAGE!"
    end
    event.respond("Unexpected exception thrown! (" + error.message + ")\n\nPlease drop us a message in the #support channel on the dice maiden server, or create an issue on Github.")
  end
end

@bot.run :async

# Check every 5 minutes and log server count
loop do
  sleep 300
  time = Time.now.getutc
  if @bot.connected? == true
    server_parse = @bot.servers.count
    $db.execute "update shard_stats set server_count = #{server_parse}, timestamp = CURRENT_TIMESTAMP where shard_id = #{@shard}"
    File.open('dice_rolls.log', 'a') { |f| f.puts "#{time} Shard: #{@shard} Server Count: #{server_parse}" }
  else
    $db.execute "update shard_stats set server_count = 0, timestamp = CURRENT_TIMESTAMP where shard_id = #{@shard}"
    File.open('dice_rolls.log', 'a') { |f| f.puts "#{time} Shard: #{@shard} bot not ready!" }
  end
  # Limit HTTP POST to shard 0. We do not need every shard hitting the discorbots API
  if @shard == 0
    servers = $db.execute "select sum(server_count) from shard_stats;"
    RestClient.post("https://discordbots.org/api/bots/377701707943116800/stats", {"shard_count": @total_shards, "server_count": servers.join.to_i}, :'Authorization' => ENV['API'], :'Content-Type' => :json);
  end
end
