#
# This file is part of Astarte.
#
# Copyright 2017-2018 Ispirata Srl
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#    http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#

defmodule Astarte.RealmManagement.API.Interfaces do
  @moduledoc """
  Astarte.Realm Management API Interfaces module.
  """
  alias Astarte.Core.Mapping.EndpointsAutomaton
  alias Astarte.RealmManagement.API.Interfaces.Queries
  alias Astarte.Core.Mapping
  alias Astarte.Core.Interface
  alias Astarte.RealmManagement.API.RPC.RealmManagement

  require Logger

  def list_interfaces(realm_name) do
    RealmManagement.get_interfaces_list(realm_name)
  end

  def list_interface_major_versions(realm_name, id) do
    with {:ok, interface_versions_list} <-
           RealmManagement.get_interface_versions_list(realm_name, id),
         interface_majors <- Enum.map(interface_versions_list, fn el -> el[:major_version] end) do
      {:ok, interface_majors}
    end
  end

  def get_interface(realm_name, interface_name, interface_major_version) do
    RealmManagement.get_interface(realm_name, interface_name, interface_major_version)
  end

  @doc """
  Creates a new interface in the specified realm.
  It builds the interface from the given parameters, verifies that the mappings
  do not exceed the maximum storage retention allowed for the realm,
  and checks if the interface can be installed (i.e., it does not already exist
  with the same name and major version).
  If all checks pass, it builds the automaton for the mappings and starts the
  installation process.

  ## Parameters
  - `realm_name`: The name of the realm where the interface will be created.
  - `params`: A map containing the interface parameters, including name, major version,
    and mappings.
  - `opts`: Optional parameters, such as `async` to determine if the installation
    should be performed asynchronously.

  ## Returns
  - `{:ok, interface}`: If the interface was successfully created and installed.
  - `{:error, reason}`: If there was an error during the creation or installation process.
  """
  @spec install_interface(String.t(), Map.t(), Keyword.t()) ::
          {:ok, Interface.t()} | {:error, term()}
  def install_interface(realm_name, params, opts \\ []) do
    with {:ok, interface} <- build_interface(params),
         :ok <- verify_mappings_max_storage_retention(realm_name, interface),
         :ok <- can_install_interface?(realm_name, interface.name, interface.major_version),
         :ok <- name_collisions?(realm_name, interface.name),
         {:ok, automaton} <- EndpointsAutomaton.build(interface.mappings) do
      Logger.info("Installing interface.",
        interface: interface.name,
        interface_major: interface.major_version,
        tag: "install_interface_started"
      )

      to_run =
        case opts[:async] do
          true ->
            fn -> Task.start(Queries, :install_interface, [realm_name, interface, automaton]) end

          _ ->
            fn -> Queries.install_interface(realm_name, interface, automaton) |> dbg() end
        end

      case to_run.() do
        {:error, reason} ->
          Logger.error("Error installing interface.",
            interface: interface.name,
            interface_major: interface.major_version,
            reason: reason,
            tag: "install_interface_failed"
          )

          {:error, reason}

        :ok ->
          {:ok, interface}

        {:ok, _pid} ->
          {:ok, interface}
      end
    end
  end

  defp build_interface(params) do
    %Interface{}
    |> Interface.changeset(params)
    |> Ecto.Changeset.apply_action(:insert)
  end

  defp verify_mappings_max_storage_retention(realm_name, interface) do
    with {:ok, max_retention} <- get_datastream_maximum_storage_retention(realm_name) do
      case mappings_retention_valid?(interface.mappings, max_retention) do
        true -> :ok
        false -> {:error, :maximum_database_retention_exceeded}
      end
    end
  end

  defp get_datastream_maximum_storage_retention(realm_name) do
    with {:error, reason} <- Queries.get_datastream_maximum_storage_retention(realm_name) do
      _ =
        Logger.warning(
          "Cannot get maximum datastream storage retention for realm #{realm_name}",
          tag: "get_datastream_maximum_storage_retention_fail"
        )

      {:error, reason}
    end
  end

  defp can_install_interface?(realm_name, interface_name, major_version) do
    case Queries.is_interface_major_available?(realm_name, interface_name, major_version) do
      {:ok, true} -> {:error, :already_installed_interface}
      {:ok, false} -> :ok
    end
  end

  defp name_collisions?(realm_name, interface_name) do
    normalized_name = normalize_interface_name(interface_name)

    with {:ok, names} <- Queries.all_interface_names(realm_name) do
      case Enum.all?(names, fn name -> normalize_interface_name(name) != normalized_name end) do
        true -> :ok
        false -> {:error, :interface_name_collision}
      end
    end
  end

  defp normalize_interface_name(interface_name) do
    String.replace(interface_name, "-", "")
    |> String.downcase()
  end

  defp mappings_retention_valid?(_mappings, 0), do: true

  defp mappings_retention_valid?(mappings, max_retention) do
    Enum.all?(mappings, fn %Mapping{database_retention_ttl: retention} ->
      retention <= max_retention
    end)
  end

  def update_interface(realm_name, interface_name, major_version, params, opts \\ []) do
    changeset = Interface.changeset(%Interface{}, params)

    with {:ok, %Interface{} = interface} <- Ecto.Changeset.apply_action(changeset, :insert),
         {:name_matches, true} <- {:name_matches, interface_name == interface.name},
         {:major_matches, true} <- {:major_matches, major_version == interface.major_version},
         {:ok, interface_source} <- Jason.encode(interface) do
      case RealmManagement.update_interface(realm_name, interface_source, opts) do
        :ok -> :ok
        {:ok, :started} -> :ok
        {:error, reason} -> {:error, reason}
      end
    else
      {:name_matches, false} ->
        {:error, :name_not_matching}

      {:major_matches, false} ->
        {:error, :major_version_not_matching}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def delete_interface(
        realm_name,
        interface_name,
        interface_major_version,
        opts \\ []
      ) do
    case RealmManagement.delete_interface(
           realm_name,
           interface_name,
           interface_major_version,
           opts
         ) do
      :ok -> :ok
      {:ok, :started} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
