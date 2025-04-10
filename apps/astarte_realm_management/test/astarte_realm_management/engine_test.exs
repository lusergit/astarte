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
  alias Astarte.RealmManagement.Engine
  use Astarte.RealmManagement.DataCase
  use ExUnitProperties

  describe "Test interface" do
    property "is installed properly", %{realm: realm} do
      gen all(interface <- Astarte.Core.Generators.Interface.interface()) do
        json_interface = Jason.encode!(interface)

        _ = Engine.install_interface(realm, json_interface)

        {:ok, interfaces} = Engine.get_interfaces_list(realm)
        assert interface.name in interfaces
      end
    end
  end
end
