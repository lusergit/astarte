#
# This file is part of Astarte.
#
# Astarte is free software: you can redistribute it and/or modify
# it under the terms of the GNU Affero General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# Astarte is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with Astarte.  If not, see <http://www.gnu.org/licenses/>.
#
# Copyright (C) 2017 Ispirata Srl
#

defmodule Astarte.DataUpdaterPlant.DataUpdater.Impl do
  use GenServer
  alias Astarte.Core.CQLUtils
  alias Astarte.Core.InterfaceDescriptor
  alias Astarte.Core.Mapping
  alias Astarte.Core.Mapping.EndpointsAutomaton
  alias Astarte.DataUpdaterPlant.DataUpdater.State
  alias Astarte.DataUpdaterPlant.SimpleTriggersProtobuf.AMQPTriggerTarget
  alias Astarte.DataUpdaterPlant.ValueMatchOperators
  alias CQEx.Client, as: DatabaseClient
  alias CQEx.Query, as: DatabaseQuery
  alias CQEx.Result, as: DatabaseResult
  require Logger

  def init_state(realm, device_id) do
    new_state = %State{
      realm: realm,
      device_id: device_id
    }

    db_client = connect_to_db(new_state)

    device_row_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement("SELECT total_received_msgs, total_received_bytes, introspection FROM devices WHERE device_id=:device_id")
      |> DatabaseQuery.put(:device_id, device_id)

    device_row =
      DatabaseQuery.call!(db_client, device_row_query)
      |> DatabaseResult.head()

    %{new_state |
      connected: true,
      total_received_msgs: device_row[:total_received_msgs],
      total_received_bytes: device_row[:total_received_bytes],
      introspection: Enum.into(device_row[:introspection], %{}),
      interfaces: %{},
      interface_ids_to_name: %{},
      mappings: %{},
      device_triggers: %{},
      data_triggers: %{},
      introspection_triggers: %{}
    }
  end

  def handle_connection(state, ip_address, _delivery_tag, timestamp) do
    db_client = connect_to_db(state)

    device_update_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement("UPDATE devices SET connected=true, last_connection=:last_connection, last_seen_ip=:last_seen_ip WHERE device_id=:device_id")
      |> DatabaseQuery.put(:device_id, state.device_id)
      |> DatabaseQuery.put(:last_connection, timestamp)
      |> DatabaseQuery.put(:last_seen_ip, ip_address)

    DatabaseQuery.call!(db_client, device_update_query)

    on_device_connection(state)

    state
  end

  def handle_disconnection(state, _delivery_tag, timestamp) do
    db_client = connect_to_db(state)

    device_update_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement("UPDATE devices SET connected=false, last_disconnection=:last_disconnection, " <>
        "total_received_msgs=:total_received_msgs, total_received_bytes=:total_received_bytes " <>
        "WHERE device_id=:device_id")
      |> DatabaseQuery.put(:device_id, state.device_id)
      |> DatabaseQuery.put(:last_disconnection, timestamp)
      |> DatabaseQuery.put(:total_received_msgs, state.total_received_msgs)
      |> DatabaseQuery.put(:total_received_bytes, state.total_received_bytes)

    DatabaseQuery.call!(db_client, device_update_query)

    on_device_disconnection(state)

    %{state |
      connected: false
    }
  end

  def handle_data(state, interface, path, payload, delivery_tag, timestamp) do
    db_client = connect_to_db(state)

    {interface_descriptor, new_state} = maybe_handle_cache_miss(Map.get(state.interfaces, interface), interface, state, db_client)

    {resolve_result, endpoint} =
      case interface_descriptor.aggregation do
        :individual ->
          {resolve_result, endpoint_id} = EndpointsAutomaton.resolve_path(path, interface_descriptor.automaton)
          endpoint = Map.get(new_state.mappings, endpoint_id)

          {resolve_result, endpoint}

        :object ->
          {:ok, %Mapping{}}
      end

    #TODO: use different BSON library
    decoded_payload = Bson.decode(payload)
    value =
      case decoded_payload do
        %{v: bson_value} -> bson_value
        %{} = bson_value -> bson_value
        _ -> :error
      end

    result =
      cond do
        interface_descriptor.ownership == :server ->
          Logger.warn "#{state.realm}: Device #{inspect state.device_id} tried to write on server owned interface: #{interface}."
          {:error, :maybe_outdated_introspection}

        resolve_result != :ok ->
          Logger.warn "#{state.realm}: Cannot resolve #{path} to #{interface} endpoint."
          {:error, :maybe_outdated_introspection}

        value == :error ->
          Logger.warn "#{state.realm}: Invalid BSON payload: #{inspect payload} sent to #{interface}#{path}."
          {:error, :invalid_message}

        true ->
          any_interface_triggers = get_on_data_triggers(new_state, :on_incoming_data, :any_interface, :any_endpoint)
          Enum.each(any_interface_triggers, fn(trigger) ->
            process_trigger(state, trigger, delivery_tag, path, value)
          end)

          any_endpoint_triggers = get_on_data_triggers(new_state, :on_incoming_data, interface_descriptor.interface_id, :any_endpoint )
          Enum.each(any_endpoint_triggers, fn(trigger) ->
            process_trigger(state, trigger, delivery_tag, path, value)
          end)

          incoming_data_triggers = get_on_data_triggers(new_state, :on_incoming_data, interface_descriptor.interface_id, endpoint.endpoint_id, path, value)
          Enum.each(incoming_data_triggers, fn(trigger) ->
            process_trigger(state, trigger, delivery_tag, path, value)
          end)

          value_change_triggers = get_on_data_triggers(new_state, :on_value_change, interface_descriptor.interface_id, endpoint.endpoint_id, path, value)
          value_changed_triggers = get_on_data_triggers(new_state, :on_value_changed, interface_descriptor.interface_id, endpoint.endpoint_id, path, value)
          path_created_triggers = get_on_data_triggers(new_state, :on_path_created, interface_descriptor.interface_id, endpoint.endpoint_id, path, value)

          previous_value =
            if (value_change_triggers != []) or (value_changed_triggers != []) or (path_created_triggers != []) do
              retrieved_value = query_previous_value(db_client, interface_descriptor.aggregation, interface_descriptor.type, state.device_id, interface_descriptor, endpoint.endpoint_id, endpoint, path)
              if retrieved_value != value do
                Enum.each(value_change_triggers, fn(trigger) ->
                  process_trigger(state, trigger, delivery_tag, path, value)
                end)
              end
            else
              nil
            end

          result = insert_value_into_db(db_client, interface_descriptor.storage_type, state.device_id, interface_descriptor, endpoint.endpoint_id, endpoint, path, value, timestamp)

          if (previous_value == nil) and (path_created_triggers != []) do
              Enum.each(path_created_triggers, fn(trigger) ->
                process_trigger(state, trigger, delivery_tag, path, value)
              end)
          end

          if (previous_value != nil) and (value_changed_triggers != []) do
              Enum.each(path_created_triggers, fn(trigger) ->
                process_trigger(state, trigger, delivery_tag, path, value)
              end)
          end

          result
      end

    if result != :ok do
      Logger.debug "result is #{inspect result} further actions should be required."
    end

    %{new_state |
      total_received_msgs: new_state.total_received_msgs + 1,
      total_received_bytes: new_state.total_received_bytes + byte_size(payload) + byte_size(interface) + byte_size(path)
    }
  end

  def handle_introspection(state, payload, delivery_tag, _timestamp) do
    db_client = connect_to_db(state)

    new_introspection_list = String.split(payload, ";")

    db_introspection_map =
      List.foldl(new_introspection_list, %{}, fn(introspection_item, introspection_map) ->
        [interface_name, major_version_string, _minor_version] = String.split(introspection_item, ":")
        {major_version, garbage} = Integer.parse(major_version_string)

        if garbage != "" do
          Logger.warn "#{state.realm}: Device #{pretty_device_id(state.device_id)} sent malformed introspection entry, found garbage: #{garbage}."
        end

        Map.put(introspection_map, interface_name, major_version)
      end)

    current_sorted_introspection =
      state.introspection
      |> Enum.map(fn(x) -> x end)
      |> Enum.sort()

    new_sorted_introspection =
      db_introspection_map
      |> Enum.map(fn(x) -> x end)
      |> Enum.sort()

    diff = List.myers_difference(current_sorted_introspection, new_sorted_introspection)
    Enum.each(diff, fn({change_type, changed_interfaces}) ->
      case change_type do
        :ins ->
          Logger.debug "#{state.realm}: Interfaces #{inspect changed_interfaces} have been added to #{pretty_device_id(state.device_id)} ."
          Enum.each(changed_interfaces, fn({interface_name, interface_major}) ->
            introspection_triggers = Map.get(state.introspection_triggers, {:on_interface_added, :any_interface}, [])
            Enum.each(introspection_triggers, fn(introspection_trigger) ->
              Enum.each(introspection_trigger.trigger_targets, fn(trigger_target) ->
                push_event_on_target(state, trigger_target, nil, delivery_tag, {:added_interface, interface_name, interface_major})
              end)
            end)
          end)

        :del ->
          Logger.debug "#{state.realm}: Interfaces #{inspect changed_interfaces} have been removed from #{pretty_device_id(state.device_id)} ."
          Enum.each(changed_interfaces, fn({interface_name, interface_major}) ->
            introspection_triggers = Map.get(state.introspection_triggers, {:on_interface_deleted, :any_interface}, [])
            Enum.each(introspection_triggers, fn(introspection_trigger) ->
              Enum.each(introspection_trigger.trigger_targets, fn(trigger_target) ->
                push_event_on_target(state, trigger_target, nil, delivery_tag, {:deleted_interface, interface_name, interface_major})
              end)
            end)
          end)

        :eq ->
          Logger.debug "#{state.realm}: Interfaces #{inspect changed_interfaces} have not changed on #{pretty_device_id(state.device_id)} ."
      end
    end)

    device_update_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement("UPDATE devices SET introspection=:introspection WHERE device_id=:device_id")
      |> DatabaseQuery.put(:device_id, state.device_id)
      |> DatabaseQuery.put(:introspection, db_introspection_map)

    DatabaseQuery.call!(db_client, device_update_query)

    %{state |
      introspection: db_introspection_map,
      total_received_msgs: state.total_received_msgs + 1,
      total_received_bytes: state.total_received_bytes + byte_size(payload)
    }
  end

  def handle_control(state, "/producer/properties", <<0, 0, 0, 0>> , _delivery_tag, _timestamp) do
    operation_result = prune_device_properties(state, "")

    if operation_result != :ok do
      Logger.debug "result is #{inspect operation_result} further actions should be required."
    end

    #TODO: ACK here

    %{state |
      total_received_msgs: state.total_received_msgs + 1,
      total_received_bytes: state.total_received_bytes + byte_size(<<0, 0, 0, 0>>) + byte_size("/producer/properties")
    }
  end

  def handle_control(state, "/producer/properties", payload, _delivery_tag, _timestamp) do
    #TODO: check payload size, to avoid anoying crashes

    <<_size_header :: size(32), zlib_payload :: binary>> = payload
    #TODO: uncompress is not safe
    decoded_payload = :zlib.uncompress(zlib_payload)

    operation_result = prune_device_properties(state, decoded_payload)

    if operation_result != :ok do
      Logger.debug "result is #{inspect operation_result} further actions should be required."
    end

    #TODO: ACK here

    %{state |
      total_received_msgs: state.total_received_msgs + 1,
      total_received_bytes: state.total_received_bytes + byte_size(payload) + byte_size("/producer/properties")
    }
  end

  def handle_control(_state, "/emptyCache", _payload,_delivery_tag, _timestamp) do
    #TODO: implement empty cache
    raise "TODO"
  end

  def handle_control(_state, path, payload, _delivery_tag, _timestamp) do
    IO.puts "Control on #{path}, payload: #{inspect payload}"

    raise "TODO or unexpected"
  end

  defp maybe_handle_cache_miss(nil, interface_name, state, db_client) do
    major_version = interface_version!(db_client, state.device_id, interface_name)
    interface_row = retrieve_interface_row!(db_client, interface_name, major_version)

    interface_descriptor = InterfaceDescriptor.from_db_result!(interface_row)

    endpoint_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement("SELECT endpoint, value_type, reliabilty, retention, expiry, allow_unset, endpoint_id, interface_id FROM endpoints WHERE interface_id=:interface_id")
      |> DatabaseQuery.put(:interface_id, interface_descriptor.interface_id)

    mappings =
      DatabaseQuery.call!(db_client, endpoint_query)
      |> Enum.reduce(state.mappings, fn(endpoint_row, acc) ->
        mapping = Mapping.from_db_result!(endpoint_row)
        Map.put(acc, mapping.endpoint_id, mapping)
      end)

    new_state = %State{state |
      interfaces: Map.put(state.interfaces, interface_name, interface_descriptor),
      interface_ids_to_name:  Map.put(state.interface_ids_to_name, interface_descriptor.interface_id, interface_name),
      mappings: mappings
    }

    {interface_descriptor, new_state}
  end

  defp maybe_handle_cache_miss(interface_descriptor, _interface_name, state, _db_client) do
    {interface_descriptor, state}
  end

  defp insert_value_into_db(db_client, :multi_interface_individual_properties_dbtable, device_id, interface_descriptor, endpoint_id, endpoint, path, value, timestamp) do
    # TODO: :reception_timestamp_submillis is just a place holder right now
    insert_query =
      DatabaseQuery.new()
        |> DatabaseQuery.statement("INSERT INTO #{interface_descriptor.storage} " <>
          "(device_id, interface_id, endpoint_id, path, reception_timestamp, #{CQLUtils.type_to_db_column_name(endpoint.value_type)}) " <>
          "VALUES (:device_id, :interface_id, :endpoint_id, :path, :reception_timestamp, :value);")
        |> DatabaseQuery.put(:device_id, device_id)
        |> DatabaseQuery.put(:interface_id, interface_descriptor.interface_id)
        |> DatabaseQuery.put(:endpoint_id, endpoint_id)
        |> DatabaseQuery.put(:path, path)
        |> DatabaseQuery.put(:reception_timestamp, timestamp)
        |> DatabaseQuery.put(:reception_timestamp_submillis, 0)
        |> DatabaseQuery.put(:value, value)

    DatabaseQuery.call!(db_client, insert_query)

    :ok
  end

  defp insert_value_into_db(db_client, :multi_interface_individual_datastream_dbtable, device_id, interface_descriptor, endpoint_id, endpoint, path, value, timestamp) do
    # TODO: use received value_timestamp when needed
    # TODO: :reception_timestamp_submillis is just a place holder right now
    insert_query =
      DatabaseQuery.new()
        |> DatabaseQuery.statement("INSERT INTO #{interface_descriptor.storage} " <>
          "(device_id, interface_id, endpoint_id, path, value_timestamp, reception_timestamp, reception_timestamp_submillis, #{CQLUtils.type_to_db_column_name(endpoint.value_type)}) " <>
          "VALUES (:device_id, :interface_id, :endpoint_id, :path, :value_timestamp, :reception_timestamp, :reception_timestamp_submillis, :value);")
        |> DatabaseQuery.put(:device_id, device_id)
        |> DatabaseQuery.put(:interface_id, interface_descriptor.interface_id)
        |> DatabaseQuery.put(:endpoint_id, endpoint_id)
        |> DatabaseQuery.put(:path, path)
        |> DatabaseQuery.put(:value_timestamp, timestamp)
        |> DatabaseQuery.put(:reception_timestamp, timestamp)
        |> DatabaseQuery.put(:reception_timestamp_submillis, 0)
        |> DatabaseQuery.put(:value, value)

    DatabaseQuery.call!(db_client, insert_query)

    :ok
  end

  defp insert_value_into_db(db_client, :one_object_datastream_dbtable, device_id, interface_descriptor, _endpoint_id, _endpoint, _path, value, timestamp) do
    #TODO: we should cache endpoints by interface_id
    endpoint_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement("SELECT endpoint, value_type FROM endpoints WHERE interface_id=:interface_id;")
      |> DatabaseQuery.put(:interface_id, interface_descriptor.interface_id)

    endpoint_rows = DatabaseQuery.call!(db_client, endpoint_query)

    #FIXME: new atoms are created here, we should avoid this. We need to fix our BSON decoder before, and to understand better CQEx code.
    column_atoms =
      Enum.reduce(endpoint_rows, %{}, fn(endpoint, column_atoms_acc) ->
        [endpoint_name] =
          endpoint[:endpoint]
          |> String.split("/")
          |> tl

        column_name = CQLUtils.endpoint_to_db_column_name(endpoint_name)

        Map.put(column_atoms_acc, String.to_atom(endpoint_name), String.to_atom(column_name))
      end)

    {query_values, placeholders, query_columns} =
      Enum.reduce(value, {%{}, "", ""}, fn({obj_key, obj_value}, {query_values_acc, placeholders_acc, query_acc}) ->
        if column_atoms[obj_key] != nil do
          column_name = CQLUtils.endpoint_to_db_column_name(to_string(obj_key))

          next_query_values_acc = Map.put(query_values_acc, column_atoms[obj_key], obj_value)
          next_placeholders_acc = "#{placeholders_acc} :#{to_string(column_atoms[obj_key])},"
          next_query_acc = "#{query_acc} #{column_name}, "

          {next_query_values_acc, next_placeholders_acc, next_query_acc}
        else
          Logger.warn "Unexpected object key #{inspect obj_key} with value #{inspect obj_value}"
          query_values_acc
        end
      end)

    # TODO: use received value_timestamp when needed
    # TODO: :reception_timestamp_submillis is just a place holder right now
    insert_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement("INSERT INTO #{interface_descriptor.storage} (device_id, #{query_columns} reception_timestamp, reception_timestamp_submillis) " <>
                                 "VALUES (:device_id, #{placeholders} :reception_timestamp, :reception_timestamp_submillis);")
      |> DatabaseQuery.put(:device_id, device_id)
      |> DatabaseQuery.put(:reception_timestamp, timestamp)
      |> DatabaseQuery.put(:reception_timestamp_submillis, 0)
      |> DatabaseQuery.merge(query_values)

    DatabaseQuery.call!(db_client, insert_query)

    :ok
  end

  defp parse_device_properties_payload(_state, "") do
    MapSet.new()
  end

  defp parse_device_properties_payload(state, decoded_payload) do
      decoded_payload
      |> String.split(";")
      |> List.foldl(MapSet.new(), fn(property_full_path, paths_acc) ->
        if property_full_path != nil do
          case String.split(property_full_path, "/", parts: 2) do
            [interface, path] ->
              if Map.has_key?(state.introspection, interface) do
                MapSet.put(paths_acc, {interface, "/" <> path})
              else
                paths_acc
              end

            _ ->
              Logger.warn "#{state.realm}: Device #{pretty_device_id(state.device_id)} sent a malformed entry in device properties control message: #{inspect property_full_path}."
              paths_acc
          end
        else
          paths_acc
        end
      end)
  end

  defp prune_device_properties(state, decoded_payload) do
    paths_set = parse_device_properties_payload(state, decoded_payload)

    db_client = connect_to_db(state)

    Enum.each(state.introspection, fn({interface, _}) ->
      prune_interface(state, db_client, interface, paths_set)
    end)

    :ok
  end

  defp prune_interface(state, db_client, interface, all_paths_set) do
    {interface_descriptor, new_state} = maybe_handle_cache_miss(Map.get(state.interfaces, interface), interface, state, db_client)

    cond do
      interface_descriptor.type != :properties ->
        {:ok, state}

      interface_descriptor.ownership != :thing ->
        Logger.warn "#{state.realm}: Device #{pretty_device_id(state.device_id)} tried to write on server owned interface: #{interface}."
        {:error, :maybe_outdated_introspection}

      true ->
        Enum.each(new_state.mappings, fn({endpoint_id, mapping}) ->
          if mapping.interface_id == interface_descriptor.interface_id do
            all_paths_query =
              DatabaseQuery.new()
                |> DatabaseQuery.statement("SELECT path FROM #{interface_descriptor.storage} WHERE device_id=:device_id AND interface_id=:interface_id AND endpoint_id=:endpoint_id")
                |> DatabaseQuery.put(:device_id, state.device_id)
                |> DatabaseQuery.put(:interface_id, interface_descriptor.interface_id)
                |> DatabaseQuery.put(:endpoint_id, endpoint_id)

            DatabaseQuery.call!(db_client, all_paths_query)
            |> Enum.each(fn(path_row) ->
              path = path_row[:path]
              if not MapSet.member?(all_paths_set, {interface, path}) do
                delete_property_from_db(state, db_client, interface_descriptor, path)
              end
            end)
          else
            :ok
          end
        end)

        {:ok, new_state}
    end
  end

  defp delete_property_from_db(state, db_client, interface_descriptor, path) do
    {:ok, endpoint_id} = EndpointsAutomaton.resolve_path(path, interface_descriptor.automaton)

    delete_query =
      DatabaseQuery.new()
        |> DatabaseQuery.statement("DELETE FROM #{interface_descriptor.storage} WHERE device_id=:device_id AND interface_id=:interface_id AND endpoint_id=:endpoint_id AND path=:path;")
        |> DatabaseQuery.put(:device_id, state.device_id)
        |> DatabaseQuery.put(:interface_id, interface_descriptor.interface_id)
        |> DatabaseQuery.put(:endpoint_id, endpoint_id)
        |> DatabaseQuery.put(:path, path)

    DatabaseQuery.call!(db_client, delete_query)
    :ok
  end

  defp process_trigger(state, trigger, delivery_tag, path, value) do
    Enum.each(trigger.trigger_targets, fn(target) ->
      push_event_on_target(state, target, trigger.trigger_name, delivery_tag, {path, value})
    end)
  end

  defp push_event_on_target(state, %AMQPTriggerTarget{} = trigger_target, trigger_name, delivery_tag, payload) do
    event_id = delivery_tag

    Logger.debug "#{state.realm}: Going to push event for trigger id #{inspect trigger_name} on #{pretty_device_id(state.device_id)} " <>
            "to #{inspect trigger_target.exchange} with routing key #{inspect trigger_target.routing_key}. Payload #{inspect payload}. event id: #{inspect event_id}"
  end

  defp on_device_connection(state) do
    trigger_targets = Map.get(state.device_triggers, :on_device_connection, [])
    Enum.each(trigger_targets, fn(trigger_target) ->
      push_event_on_target(state, trigger_target, nil, nil, nil)
    end)

    :ok
  end

  defp on_device_disconnection(state) do
    trigger_targets = Map.get(state.device_triggers, :on_device_disconnection, [])
    Enum.each(trigger_targets, fn(trigger_target) ->
      push_event_on_target(state, trigger_target, nil, nil, nil)
    end)

    :ok
  end

  defp get_on_data_triggers(state, event, interface_id, endpoint_id) do
    key = {event, interface_id, endpoint_id}

    Map.get(state.data_triggers, key, [])
  end

  defp get_on_data_triggers(state, event, interface_id, endpoint_id, path, value) do
    key = {event, interface_id, endpoint_id}

    candidate_triggers = Map.get(state.data_triggers, key, nil)
    if candidate_triggers do
      path_tokens = String.split(path, "/")

      for trigger <- candidate_triggers,
          path_matches?(path_tokens, trigger.path_match_tokens) and
          ValueMatchOperators.value_matches?(value, trigger.value_match_operator, trigger.known_value) do
        trigger
      end
    else
      []
    end
  end

  defp path_matches?([], []) do
    true
  end

  defp path_matches?([path_token | path_tokens], [path_match_token | path_match_tokens]) do
    if (path_token == path_match_token) or (path_match_token == nil) do
      path_matches?(path_tokens, path_match_tokens)
    else
      false
    end
  end


  #TODO: copied from AppEngine, make it an api
  defp retrieve_interface_row!(client, interface, major_version) do
    interface_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement("SELECT name, major_version, minor_version, interface_id, type, quality, flags, storage, storage_type, automaton_transitions, automaton_accepting_states FROM interfaces" <>
                                 " WHERE name=:name AND major_version=:major_version")
      |> DatabaseQuery.put(:name, interface)
      |> DatabaseQuery.put(:major_version, major_version)

    interface_row =
      DatabaseQuery.call!(client, interface_query)
      |> DatabaseResult.head()

    #if interface_row == :empty_dataset do
    #  Logger.warn "Device.retrieve_interface_row: interface not found. This error here means that the device has an interface that is not installed."
    #  raise InterfaceNotFoundError
    #end

    interface_row
  end

  #TODO: copied from AppEngine, make it an api
  defp interface_version!(client, device_id, interface) do
    device_introspection_query =
      DatabaseQuery.new()
      |> DatabaseQuery.statement("SELECT introspection FROM devices WHERE device_id=:device_id")
      |> DatabaseQuery.put(:device_id, device_id)

    device_row =
      DatabaseQuery.call!(client, device_introspection_query)
      |> DatabaseResult.head()

    #if device_row == :empty_dataset do
    #  raise DeviceNotFoundError
    #end

    interface_tuple =
      device_row[:introspection]
      |> List.keyfind(interface, 0)

    case interface_tuple do
      {_interface_name, interface_major} ->
        interface_major

      nil ->
        #TODO: report device introspection here for debug purposes
        #raise InterfaceNotFoundError
        {:error, :interface_not_found}
    end
  end

  defp query_previous_value(_db_client, :individual, :properties, _device_id, _interface_descriptor, _endpoint_id, _endpoint, _path) do
    #TODO: implement me
    nil
  end

  defp connect_to_db(state) do
    DatabaseClient.new!(List.first(Application.get_env(:cqerl, :cassandra_nodes)), [keyspace: state.realm])
  end

  defp pretty_device_id(device_id) do
    Base.url_encode64(device_id, padding: false)
  end

end
