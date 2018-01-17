require 'tempfile'
require_relative '../mac-wifi'

module MacWifi

class BaseModel

  class OsCommandError < RuntimeError
    attr_reader :exitstatus, :command, :text

    def initialize(exitstatus, command, text)
      @exitstatus = exitstatus
      @command = command
      @text = text
    end
  end


  def initialize(verbose = false)
    @verbose_mode = verbose
  end


  def run_os_command(command)
    output = `#{command} 2>&1` # join stderr with stdout
    if $?.exitstatus != 0
      raise OsCommandError.new($?.exitstatus, command, output)
    end
    if @verbose_mode
      puts "\n\n#{'-' * 79}\nCommand: #{command}\n\nOutput:\n#{output}#{'-' * 79}\n\n"
    end
    output
  end
  private :run_os_command


  # This method returns whether or not there is a working Internet connection.
  # Because of a Mac issue which causes a request to hang if the network is turned
  # off during its lifetime, we give it only 5 seconds per try,
  # and limit the number of tries to 3.
  #
  # This implementation will probably strike you as overly complex. The following
  # code looks like it is all that should be necessary, but unfortunately
  # this implementation often hangs when wifi is turned off while curl is active
  #
  # def connected_to_internet?
  #   script = "curl --silent --head http://www.google.com/ > /dev/null ; echo $?"
  #   result = `#{script}`.chomp
  #   puts result
  #   result == '0'
  # end

  # TODO Investigate using Curl options: --connect-timeout 1 --max-time 2 --retry 0
  # to greatly simplify this method.
  def connected_to_internet?

    tempfile = Tempfile.open('mac-wifi-')

    begin
      start_status_script = -> do
        script = "curl --silent --head http://www.google.com/ > /dev/null ; echo $? > #{tempfile.path} &"
        pid = Process.spawn(script)
        Process.detach(pid)
        pid
      end

      process_is_running = ->(pid) do
        script = %Q{ps -p #{pid} > /dev/null; echo $?}
        output = `#{script}`.chomp
        output == "0"
      end

      get_connected_state_from_curl = -> do
        tempfile.close
        File.read(tempfile.path).chomp == '0'
      end

      # Do one run, iterating during the timeout period to see if the command has completed
      do_one_run = -> do
        end_time = Time.now + 3
        pid = start_status_script.()
        while Time.now < end_time
          if process_is_running.(pid)
            sleep 0.5
          else
            return get_connected_state_from_curl.()
          end
        end
        Process.kill('KILL', pid) if process_is_running.(pid)
        :hung
      end

      3.times do
        connected = do_one_run.()
        return connected if connected != :hung
      end

      raise "Could not determine Internet status."

    ensure
      tempfile.unlink
    end

  end


  # Turns wifi off and then on, reconnecting to the originally connecting network.
  def cycle_network
    # TODO: Make this network name saving and restoring conditional on it not having a password.
    # If the disabled code below is enabled, an error will be raised if a password is required,
    # even though it is stored.
    # network_name = current_network
    wifi_off
    wifi_on
    # connect(network_name) if network_name
  end


  def connected_to?(network_name)
    network_name == connected_network_name
  end


  # Connects to the passed network name, optionally with password.
  # Turns wifi on first, in case it was turned off.
  # Relies on subclass implementation of os_level_connect().
  def connect(network_name, password = nil)
    # Allow symbols and anything responding to to_s for user convenience
    network_name = network_name.to_s if network_name
    password     = password.to_s     if password

    if network_name.nil? || network_name.empty?
      raise "A network name is required but was not provided."
    end
    wifi_on
    os_level_connect(network_name, password)

    # Verify that the network is now connected:
    actual_network_name = connected_network_name
    unless actual_network_name == network_name
      message = %Q{Expected to connect to "#{network_name}" but }
      if actual_network_name
        message << %Q{connected to "#{connected_network_name}" instead.}
      else
        message << "unable to connect to any network. Did you "
      end
      message << (password ? "provide the correct password?" : "need to provide a password?")
      raise message
    end
    nil
  end


  # Removes the specified network(s) from the preferred network list.
  # @param network_names names of networks to remove; may be empty or contain nonexistent networks
  # @return names of the networks that were removed (excludes non-preexisting networks)
  def remove_preferred_networks(*network_names)
    networks_to_remove = network_names & preferred_networks # exclude any nonexistent networks
    networks_to_remove.each { |name| remove_preferred_network(name) }
  end


  def preferred_network_password(preferred_network_name)
    preferred_network_name = preferred_network_name.to_s
    if preferred_networks.include?(preferred_network_name)
      os_level_preferred_network_password(preferred_network_name)
    else
      raise "Network #{preferred_network_name} not in preferred networks list."
    end
  end


  # Waits for the Internet connection to be in the desired state.
  # @param target_status must be in [:conn, :disc, :off, :on]; waits for that state
  # @param wait_interval_in_secs sleeps this interval between retries; if nil or absent,
  #        a default will be provided
  #
  def till(target_status, wait_interval_in_secs = nil)

    # One might ask, why not just put the 0.5 up there as the default argument.
    # We could do that, but we'd still need the line below in case nil
    # was explicitly specified. The default argument of nil above emphasizes that
    # the absence of an argument and a specification of nil will behave identically.
    wait_interval_in_secs ||= 0.5

    finished_predicates = {
        conn: -> { connected_to_internet? },
        disc: -> { ! connected_to_internet? },
        on:   -> { wifi_on? },
        off:  -> { ! wifi_on? }
    }

    finished_predicate = finished_predicates[target_status]

    if finished_predicate.nil?
      raise ArgumentError.new(
          "Option must be one of #{finished_predicates.keys.inspect}. Was: #{target_status.inspect}")
    end

    loop do
      return if finished_predicate.()
      sleep(wait_interval_in_secs)
    end
  end


  # Tries an OS command until the stop condition is true.
  # @command the command to run in the OS
  # @stop_condition a lambda taking the commands stdout as its sole parameter
  # @return the stdout produced by the command
  def try_os_command_until(command, stop_condition, max_tries = 100)
    max_tries.times do
      stdout = run_os_command(command)
      if stop_condition.(stdout)
        return stdout
      end
    end
    nil
  end
end
end