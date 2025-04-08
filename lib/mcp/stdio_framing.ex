defmodule MCP.StdioFraming do
  @moduledoc """
  Handles reading and writing length-prefixed JSON messages over IO devices.

  Follows the Language Server Protocol (LSP) style framing:
  Content-Length: NNN\r\n
  \r\n
  {json}
  """
  require Logger

  @buffer_size 8192 # Adjust buffer size as needed
  @header_separator "\r\n\r\n"
  @header_separator_len byte_size(@header_separator)

  @doc """
  Reads a single length-prefixed JSON message from the given IO device.
  Buffers input internally.

  Returns:
    * `{:ok, binary_payload}` - The raw JSON payload as a binary.
    * `{:error, :eof}` - End of file reached.
    * `{:error, :invalid_header}` - Header format is incorrect.
    * `{:error, reason}` - Other IO error.
  """
  def read_message(io_device \\ :stdio, buffer \\ <<>>) do
    case read_headers(io_device, buffer) do
      {:ok, headers, rest_buffer} ->
        case parse_content_length(headers) do
          {:ok, content_length} ->
            read_payload(io_device, content_length, rest_buffer)
          {:error, reason} ->
            Logger.error("Failed to parse Content-Length: #{inspect(reason)} from headers: #{inspect(headers)}")
            # Continue reading with the rest_buffer, hoping for a valid message next
            read_message(io_device, rest_buffer)
            # Or return {:error, :invalid_header} ? For now, try to recover.
        end
      {:error, :need_more_data, current_buffer} ->
        # Headers not complete yet, try reading more
        case IO.binread(io_device, 8192) do
          {:ok, new_data} ->
             read_message(io_device, current_buffer <> new_data)
          :eof ->
             Logger.error("EOF reached while waiting for more header data.")
             {:error, :eof}
          {:error, reason} ->
            Logger.error("Error reading more data for headers: #{inspect(reason)}")
            {:error, reason}
        end
      {:error, reason, _buffer} -> # EOF or other read error during header search
        {:error, reason}
    end
  end

  @doc """
  Writes a binary payload as a length-prefixed JSON message to the IO device.

  Returns:
    * `:ok` - Message written successfully.
    * `{:error, reason}` - IO error.
  """
  def write_message(io_device \\ :stdio, binary_payload) when is_binary(binary_payload) do
    content_length = byte_size(binary_payload)
    header = "Content-Length: #{content_length}\r\n\r\n"

    # Use IO.binwrite for writing binary data
    case IO.binwrite(io_device, header <> binary_payload) do
      :ok -> :ok
      error -> error # Propagate {:error, reason}
    end
  end

  # --- Private Helpers ---

  # Reads from buffer/device until \r\n\r\n separator is found.
  # Returns {:ok, headers_binary, rest_of_buffer}
  # Returns {:error, :need_more_data, current_buffer} if separator not found
  # Returns {:error, reason, current_buffer} on read errors/EOF
  defp read_headers(io_device, buffer) do
    case :binary.match(buffer, @header_separator) do
      {start_index, @header_separator_len} ->
        # Found separator
        headers = :binary.part(buffer, 0, start_index)
        rest_offset = start_index + @header_separator_len
        rest_buffer = :binary.part(buffer, rest_offset, byte_size(buffer) - rest_offset)
        {:ok, headers, rest_buffer}
      :nomatch ->
        # Separator not in buffer, need more data
        {:error, :need_more_data, buffer}
    end
  end

  # Parses the Content-Length value from header binary
  defp parse_content_length(headers_binary) do
    # Convert to string for regex matching (assuming ASCII/UTF-8 headers)
    headers_string = :binary.bin_to_list(headers_binary) |> List.to_string()
    case Regex.run(~r/Content-Length: (\d+)/i, headers_string) do
      [_, length_str] ->
        case Integer.parse(length_str) do
          {length, ""} when length >= 0 ->
            {:ok, length}
          _ ->
            {:error, :invalid_length_value}
        end
      nil ->
        {:error, :missing_content_length}
    end
  end

  # Reads exactly content_length bytes for the payload, using buffer first.
  defp read_payload(io_device, content_length, buffer) when content_length >= 0 do
    buffer_size = byte_size(buffer)

    if buffer_size >= content_length do
      # Payload is fully contained within the buffer
      payload = :binary.part(buffer, 0, content_length)
      rest_buffer = :binary.part(buffer, content_length, buffer_size - content_length)
      # Return the payload and pass the remaining buffer to the next read_message call
      # We need to trigger the next read_message from somewhere.
      # Let's return {:ok, payload} and assume caller handles recursion/looping.
      # This requires changing read_message structure slightly.
      {:ok, payload, rest_buffer} # Return payload and remaining buffer
    else
      # Payload partially in buffer, need to read the rest
      needed = content_length - buffer_size
      case IO.binread(io_device, needed) do
        {:ok, rest_payload} when byte_size(rest_payload) == needed ->
          # Successfully read the remainder
          full_payload = buffer <> rest_payload
          {:ok, full_payload, <<>>} # Return payload, empty remaining buffer
        {:ok, _partial_payload} ->
          Logger.error("Read payload size mismatch (partial read): Expected #{needed}, got less.")
          {:error, :payload_read_incomplete, buffer} # Return error and original buffer
        :eof ->
          Logger.error("EOF reached while reading payload remainder (needed #{needed}).")
          {:error, :eof, buffer}
        {:error, reason} ->
          Logger.error("Error reading payload remainder: #{inspect(reason)}")
          {:error, reason, buffer}
      end
    end
  end

  # Need a top-level function to manage the buffer across calls
  def process_stream(io_device \\ :stdio, message_handler_fun) do
     process_loop(io_device, message_handler_fun, <<>>)
  end

  defp process_loop(io_device, message_handler_fun, buffer) do
    case read_message(io_device, buffer) do
       {:ok, payload, rest_buffer} ->
          try do
            message = Jason.decode!(payload)
            Logger.debug("[StdioFraming] Decoded Message: #{inspect(message)}")
            # Call the actual message handler provided by the Mix task
            response_map = message_handler_fun.(message)
            # Send response if handler returned one
            if response_map != nil do
               Logger.debug("[StdioFraming] Encoding Response Map: #{inspect(response_map)}")
               encoded_response = Jason.encode!(response_map)
               Logger.debug("[StdioFraming] Writing Framed Response (#{byte_size(encoded_response)} bytes): #{inspect(encoded_response)}")
               write_result = write_message(io_device, encoded_response)
               Logger.debug("[StdioFraming] write_message result: #{inspect(write_result)}")
               # Explicitly flush the specific IO device
               flush_result = IO.flush(io_device) # Flush the specific device
               Logger.debug("[StdioFraming] IO.flush(#{inspect(io_device)}) result: #{inspect(flush_result)}")
            end
          rescue
            e ->
              Logger.error("Error decoding/handling message: #{inspect(e)}")
              # Send JSON parse error response
              error_response = %{
                 "jsonrpc" => "2.0",
                 "id" => nil,
                 "error" => %{
                   "code" => -32700,
                   "message" => "Parse error/Internal error: #{inspect(e)}",
                   "data" => nil
                 }
               }
               Logger.debug("[StdioFraming] Writing Error Response: #{inspect(error_response)}")
               write_message(io_device, Jason.encode!(error_response))
               IO.flush(io_device) # Flush errors too
          end
          # Loop with the remaining buffer
          process_loop(io_device, message_handler_fun, rest_buffer)

       {:error, :eof} ->
          Logger.info("Stdio stream ended (EOF).")
          :ok # End loop

       {:error, reason} ->
          Logger.error("Failed to read message: #{inspect(reason)}. Exiting loop.")
          {:error, reason} # Propagate error and exit loop
    end
  end
end
