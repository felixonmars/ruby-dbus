# frozen_string_literal: true

# This file is part of the ruby-dbus project
# Copyright (C) 2007 Arnaud Cornet and Paul van Tilburg
#
# This library is free software; you can redistribute it and/or
# modify it under the terms of the GNU Lesser General Public
# License, version 2.1 as published by the Free Software Foundation.
# See the file "COPYING" for the exact licensing terms.

require "rbconfig"

module DBus
  # Exception raised when authentication fails somehow.
  class AuthenticationFailed < Exception
  end

  # = General class for authentication.
  class Authenticator
    # Returns the name of the authenticator.
    def name
      self.class.to_s.upcase.sub(/.*::/, "")
    end
  end

  # = Anonymous authentication class
  class Anonymous < Authenticator
    def authenticate
      "527562792044427573" # Hex encoded version of "Ruby DBus"
    end
  end

  # = External authentication class
  #
  # Class for 'external' type authentication.
  class External < Authenticator
    # Performs the authentication.
    def authenticate
      # Take the user id (eg integer 1000) make a string out of it "1000", take
      # each character and determin hex value "1" => 0x31, "0" => 0x30. You
      # obtain for "1000" => 31303030 This is what the server is expecting.
      # Why? I dunno. How did I come to that conclusion? by looking at rbus
      # code. I have no idea how he found that out.
      Process.uid.to_s.split(//).map { |d| d.ord.to_s(16) }.join
    end
  end

  # = Authentication class using SHA1 crypto algorithm
  #
  # Class for 'CookieSHA1' type authentication.
  # Implements the AUTH DBUS_COOKIE_SHA1 mechanism.
  class DBusCookieSHA1 < Authenticator
    # the autenticate method (called in stage one of authentification)
    def authenticate
      require "etc"
      # number of retries we have for auth
      @retries = 1
      hex_encode(Etc.getlogin).to_s # server expects it to be binary
    end

    # returns the modules name
    def name
      "DBUS_COOKIE_SHA1"
    end

    # handles the interesting crypto stuff, check the rbus-project for more info: http://rbus.rubyforge.org/
    def data(hexdata)
      require "digest/sha1"
      data = hex_decode(hexdata)
      # name of cookie file, id of cookie in file, servers random challenge
      context, id, s_challenge = data.split(" ")
      # Random client challenge
      c_challenge = 1.upto(s_challenge.bytesize / 2).map { rand(255).to_s }.join
      # Search cookie file for id
      path = File.join(ENV["HOME"], ".dbus-keyrings", context)
      DBus.logger.debug "path: #{path.inspect}"
      File.foreach(path) do |line|
        if line.start_with?(id)
          # Right line of file, read cookie
          cookie = line.split(" ")[2].chomp
          DBus.logger.debug "cookie: #{cookie.inspect}"
          # Concatenate and encrypt
          to_encrypt = [s_challenge, c_challenge, cookie].join(":")
          sha = Digest::SHA1.hexdigest(to_encrypt)
          # the almighty tcp server wants everything hex encoded
          hex_response = hex_encode("#{c_challenge} #{sha}")
          # Return response
          response = [:AuthOk, hex_response]
          return response
        end
      end
      return if @retries <= 0

      # a little rescue magic
      puts "ERROR: Could not auth, will now exit."
      puts "ERROR: Unable to locate cookie, retry in 1 second."
      @retries -= 1
      sleep 1
      data(hexdata)
    end

    # encode plain to hex
    def hex_encode(plain)
      return nil if plain.nil?

      plain.to_s.unpack1("H*")
    end

    # decode hex to plain
    def hex_decode(encoded)
      encoded.scan(/[[:xdigit:]]{2}/).map { |h| h.hex.chr }.join
    end
  end

  # Note: this following stuff is tested with External authenticator only!

  # = Authentication client class.
  #
  # Class tha performs the actional authentication.
  class Client
    # Create a new authentication client.
    def initialize(socket)
      @socket = socket
      @state = nil
      @auth_list = [External, DBusCookieSHA1, Anonymous]
    end

    # Start the authentication process.
    def authenticate
      if RbConfig::CONFIG["target_os"] =~ /freebsd/
        @socket.sendmsg(0.chr, 0, nil, [:SOCKET, :SCM_CREDS, ""])
      else
        @socket.write(0.chr)
      end
      next_authenticator
      @state = :Starting
      while @state != :Authenticated
        r = next_state
        return r if !r
      end
      true
    end

    ##########

    private

    ##########

    # Send an authentication method _meth_ with arguments _args_ to the
    # server.
    def send(meth, *args)
      o = ([meth] + args).join(" ")
      @socket.write("#{o}\r\n")
    end

    # Try authentication using the next authenticator.
    def next_authenticator
      raise AuthenticationFailed if @auth_list.empty?

      @authenticator = @auth_list.shift.new
      auth_msg = ["AUTH", @authenticator.name, @authenticator.authenticate]
      DBus.logger.debug "auth_msg: #{auth_msg.inspect}"
      send(auth_msg)
    rescue AuthenticationFailed
      @socket.close
      raise
    end

    # Read data (a buffer) from the bus until CR LF is encountered.
    # Return the buffer without the CR LF characters.
    def next_msg
      data = ""
      crlf = "\r\n"
      left = 1024 # 1024 byte, no idea if it's ever getting bigger
      while left.positive?
        buf = @socket.read(left > 1 ? 1 : left)
        break if buf.nil?

        left -= buf.bytesize
        data += buf
        break if data.include? crlf # crlf means line finished, the TCP socket keeps on listening, so we break
      end
      readline = data.chomp.split(" ")
      DBus.logger.debug "readline: #{readline.inspect}"
      readline
    end

    #     # Read data (a buffer) from the bus until CR LF is encountered.
    #     # Return the buffer without the CR LF characters.
    #     def next_msg
    #       @socket.readline.chomp.split(" ")
    #     end

    # Try to reach the next state based on the current state.
    def next_state
      msg = next_msg
      if @state == :Starting
        DBus.logger.debug ":Starting msg: #{msg[0].inspect}"
        case msg[0]
        when "OK"
          @state = :WaitingForOk
        when "CONTINUE"
          @state = :WaitingForData
        when "REJECTED" # needed by tcp, unix-path/abstract doesn't get here
          @state = :WaitingForData
        end
      end
      DBus.logger.debug "state: #{@state}"
      case @state
      when :WaitingForData
        DBus.logger.debug ":WaitingForData msg: #{msg[0].inspect}"
        case msg[0]
        when "DATA"
          chall = msg[1]
          resp, chall = @authenticator.data(chall)
          DBus.logger.debug ":WaitingForData/DATA resp: #{resp.inspect}"
          case resp
          when :AuthContinue
            send("DATA", chall)
            @state = :WaitingForData
          when :AuthOk
            send("DATA", chall)
            @state = :WaitingForOk
          when :AuthError
            send("ERROR")
            @state = :WaitingForData
          end
        when "REJECTED"
          next_authenticator
          @state = :WaitingForData
        when "ERROR"
          send("CANCEL")
          @state = :WaitingForReject
        when "OK"
          send("BEGIN")
          @state = :Authenticated
        else
          send("ERROR")
          @state = :WaitingForData
        end
      when :WaitingForOk
        DBus.logger.debug ":WaitingForOk msg: #{msg[0].inspect}"
        case msg[0]
        when "OK"
          send("BEGIN")
          @state = :Authenticated
        when "REJECT"
          next_authenticator
          @state = :WaitingForData
        when "DATA", "ERROR"
          send("CANCEL")
          @state = :WaitingForReject
        else
          send("ERROR")
          @state = :WaitingForOk
        end
      when :WaitingForReject
        DBus.logger.debug ":WaitingForReject msg: #{msg[0].inspect}"
        case msg[0]
        when "REJECT"
          next_authenticator
          @state = :WaitingForOk
        else
          @socket.close
          return false
        end
      end
      true
    end
  end
end
