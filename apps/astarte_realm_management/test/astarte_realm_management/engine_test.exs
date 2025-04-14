#
# This file is part of Astarte.
#
# Copyright 2017 - 2025 SECO Mind Srl
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

defmodule Astarte.RealmManagement.EngineTest do
  alias Astarte.RealmManagement.Queries
  alias Astarte.RealmManagement.Engine
  use Astarte.RealmManagement.DataCase
  use ExUnitProperties

  describe "Test interface" do
    property "is installed properly", %{realm: realm} do
      check all(interface <- Astarte.Core.Generators.Interface.interface()) do
        json_interface = Jason.encode!(interface)

        _ = Engine.install_interface(realm, json_interface)

        {:ok, interfaces} = Engine.get_interfaces_list(realm)
        assert interface.name in interfaces
      end
    end

    property "does not get deleted if major version is not 0", %{realm: realm} do
      check all(
              interface <-
                Astarte.Core.Generators.Interface.interface(major_version: integer(1..9))
            ) do
        json_interface = Jason.encode!(interface)

        _ = Engine.install_interface(realm, json_interface)

        assert {:error, :forbidden} =
                 Engine.delete_interface(realm, interface.name, interface.major_version)

        {:ok, interfaces} = Engine.get_interfaces_list(realm)
        assert interface.name in interfaces
      end
    end

    property "is deleted if the major version is 0", %{realm: realm} do
      check all(interface <- Astarte.Core.Generators.Interface.interface(major_version: 0)) do
        json_interface = Jason.encode!(interface)

        _ = Engine.install_interface(realm, json_interface)
        {:ok, interfaces} = Engine.get_interfaces_list(realm)

        assert :ok = Engine.delete_interface(realm, interface.name, interface.major_version)
        {:ok, interfaces} = Engine.get_interfaces_list(realm)
        refute interface.name in interfaces
      end
    end

    property "can update only the same major version", %{realm: realm} do
      check all(
              interface <-
                Astarte.Core.Generators.Interface.interface(major_version: integer(0..8)),
              update_interface <-
                Astarte.Core.Generators.Interface.interface(
                  name: interface.name,
                  major_version: interface.major_version + 1
                )
            ) do
        json_interface = Jason.encode!(interface)
        json_updated_interface = Jason.encode!(update_interface)

        _ = Engine.install_interface(realm, json_interface)

        assert {:error, :interface_major_version_does_not_exist} =
                 Engine.update_interface(realm, json_updated_interface)
      end
    end

    property "is updated with valid update", %{realm: realm} do
      check all(
              interface <-
                Astarte.Core.Generators.Interface.interface(minor_version: integer(1..254)),
              valid_update_interface <-
                Astarte.Core.Generators.Interface.interface(
                  name: interface.name,
                  major_version: interface.major_version,
                  minor_version: integer((interface.minor_version + 1)..255),
                  type: interface.type,
                  ownership: interface.ownership,
                  aggregation: interface.aggregation,
                  interface_id: interface.interface_id,
                  mappings: interface.mappings
                )
            ) do
        json_interface = Jason.encode!(interface)
        json_updated_interface = Jason.encode!(valid_update_interface)

        _ = Engine.install_interface(realm, json_interface)
        :ok = Engine.update_interface(realm, json_updated_interface)

        {:ok, interface} =
          Queries.fetch_interface(realm, interface.name, interface.major_version)

        %{
          name: name,
          major_version: major,
          minor_version: minor
        } = interface

        assert %Astarte.Core.Interface{
                 name: ^name,
                 major_version: ^major,
                 minor_version: ^minor
               } = valid_update_interface
      end
    end

    property "is not updated on downgrade", %{realm: realm} do
      check all(
              interface <-
                Astarte.Core.Generators.Interface.interface(minor_version: integer(2..255)),
              updated_interface <-
                Astarte.Core.Generators.Interface.interface(
                  name: interface.name,
                  major_version: interface.major_version,
                  minor_version: interface.minor_version - 1,
                  type: interface.type,
                  ownership: interface.ownership,
                  aggregation: interface.aggregation,
                  interface_id: interface.interface_id,
                  mappings: interface.mappings
                )
            ) do
        json_interface = Jason.encode!(interface)
        json_updated_interface = Jason.encode!(updated_interface)

        _ = Engine.install_interface(realm, json_interface)
        {:error, :downgrade_not_allowed} = Engine.update_interface(realm, json_updated_interface)
      end
    end
  end
end
