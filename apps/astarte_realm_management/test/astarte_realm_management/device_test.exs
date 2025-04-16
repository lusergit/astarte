#
# This file is part of Astarte.
#
# Copyright 2025 SECO Mind Srl
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
# SPDX-License-Identifier: Apache-2.0
#

defmodule Astarte.RealmManagement.DeviceTest do
  @moduledoc """
  Test for the `Device` section of the RealmManagement Engine
  """
  alias Astarte.RealmManagement.Engine
  alias Astarte.DataAccess.Realms.Realm
  alias Astarte.RealmManagement.Repo
  alias Astarte.DataAccess.Device.DeletionInProgress
  alias Astarte.Core.Device
  alias Astarte.RealmManagement.DatabaseTestHelper

  use Astarte.RealmManagement.DataCase, async: true
  use ExUnitProperties

  describe "Test device" do
    @describetag :devices
    property "gets put in deletion in progress on deletion request", %{realm: realm} do
      check all(
              interface <- Astarte.Core.Generators.Interface.interface(),
              device <- Astarte.Core.Generators.Device.device(interfaces: interface)
            ) do
        DatabaseTestHelper.seed_devices_test_data!(realm_name: realm, device_id: device.device_id)

        encoded_device_id = Device.encode_device_id(device.device_id)
        assert :ok = Engine.delete_device(realm, encoded_device_id)

        {:ok, deletion} = Repo.fetch_one(DeletionInProgress, prefix: Realm.keyspace_name(realm))

        assert deletion.device_id == device.device_id
        refute deletion.vmq_ack
        refute deletion.dup_start_ack
        refute deletion.dup_end_ack

        _ = Repo.delete!(deletion)
      end
    end
  end
end
