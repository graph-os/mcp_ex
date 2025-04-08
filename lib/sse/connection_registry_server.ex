defmodule SSE.ConnectionRegistryServer do
  @moduledoc """
  GenServer implementation for managing SSE connection state synchronously.
  Replaces the use of Registry for session data storage to avoid race conditions.
  """
  use GenServer
  require Logger

  # Client API

  @doc """
  Starts the registry GenServer.
  """
  def start_link(opts \\ []) do
    # Use a name for easy access, matching the old Registry name if possible
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, %{}, name: name)
  end

  @doc """
  Registers a connection with the given session ID and initial data.
  Synchronous operation.
  """
  def register(server \\ __MODULE__, session_id, initial_data \\ %{}) do
    GenServer.call(server, {:register, session_id, initial_data})
  end

  @doc """
  Unregisters a connection by session ID.
  Synchronous operation.
  """
  def unregister(server \\ __MODULE__, session_id) do
    GenServer.call(server, {:unregister, session_id})
  end

  @doc """
  Looks up connection data by session ID.
  Returns `{:ok, data}` or `{:error, :not_found}`.
  Synchronous operation.
  """
  def lookup(server \\ __MODULE__, session_id) do
    GenServer.call(server, {:lookup, session_id})
  end

  @doc """
  Updates the data for a registered session ID.
  Merges the `new_data` map with the existing data.
  Returns `:ok` or `{:error, :not_found}`.
  Synchronous operation.
  """
  def update_data(server \\ __MODULE__, session_id, new_data) do
    GenServer.call(server, {:update_data, session_id, new_data})
  end

  @doc """
  Returns a map of all active sessions (session_id => data).
  Synchronous operation.
  """
  def list_sessions(server \\ __MODULE__) do
    GenServer.call(server, :list_sessions)
  end

  # Server Callbacks

  @impl true
  def init(initial_state) do
    Logger.info("SSE Connection Registry GenServer started.")
    # State is a map: %{session_id => {data_map, monitor_ref | nil}}
    {:ok, initial_state}
  end

  @impl true
  def handle_call({:register, session_id, initial_data}, _from, state) do
    Logger.debug("RegistryServer: Registering session #{session_id}")
    if Map.has_key?(state, session_id) do
      {:reply, {:error, :already_registered}, state}
    else
      # Monitor the handler_pid if present
      monitor_ref =
        case Map.get(initial_data, :handler_pid) do
          pid when is_pid(pid) -> Process.monitor(pid)
          _ -> nil
        end
      new_state = Map.put(state, session_id, {initial_data, monitor_ref})
      {:reply, :ok, new_state}
    end
  end

  @impl true
  def handle_call({:unregister, session_id}, _from, state) do
    Logger.debug("RegistryServer: Unregistering session #{session_id}")
    case Map.get(state, session_id) do
      {_data, monitor_ref} when not is_nil(monitor_ref) ->
        Process.demonitor(monitor_ref, [:flush])
      _ ->
        :ok # No monitor ref to demonitor
    end
    new_state = Map.delete(state, session_id)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call({:lookup, session_id}, _from, state) do
    Logger.debug("RegistryServer: Looking up session #{session_id}")
    reply =
      case Map.get(state, session_id) do
        {data, _monitor_ref} -> {:ok, data}
        nil -> {:error, :not_found}
      end
    {:reply, reply, state}
  end

  @impl true
  def handle_call({:update_data, session_id, new_data}, _from, state) do
    Logger.debug("RegistryServer: Updating data for session #{session_id}")
    case Map.get(state, session_id) do
      {existing_data, monitor_ref} ->
        merged_data = Map.merge(existing_data, new_data)
        new_state = Map.put(state, session_id, {merged_data, monitor_ref})
        {:reply, :ok, new_state}
      nil ->
        {:reply, {:error, :not_found}, state}
    end
  end

  @impl true
  def handle_call(:list_sessions, _from, state) do
    Logger.debug("RegistryServer: Listing sessions")
    # Extract just the data map for the reply
    sessions_data = Map.new(state, fn {session_id, {data, _ref}} -> {session_id, data} end)
    {:reply, sessions_data, state}
  end

  # Handle DOWN messages for monitored handler processes
  @impl true
  def handle_info({:DOWN, ref, :process, _pid, reason}, state) do
    Logger.debug("RegistryServer: Received DOWN for monitor ref #{inspect ref}, reason: #{inspect reason}")
    # Find session associated with this monitor ref and remove it
    session_id_to_remove =
      Enum.find_value(state, fn {session_id, {_data, monitor_ref}} ->
        if monitor_ref == ref, do: session_id, else: nil
      end)

    if session_id_to_remove do
      Logger.info("RegistryServer: Cleaning up session #{session_id_to_remove} due to monitored process exit.")
      new_state = Map.delete(state, session_id_to_remove)
      {:noreply, new_state}
    else
      # Monitor ref not found (might have been demonitored already)
      {:noreply, state}
    end
  end

  # Catch-all for other messages
  @impl true
  def handle_info(msg, state) do
    Logger.warning("RegistryServer: Received unexpected message: #{inspect msg}")
    {:noreply, state}
  end
end
