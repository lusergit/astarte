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

defmodule Astarte.RealmManagement.QueriesTest do
  use Astarte.RealmManagement.DataCase
  use ExUnitProperties
  import Ecto.Query

  alias Astarte.Core.Triggers.SimpleEvents.InterfaceVersion
  alias Astarte.RealmManagement.JWTPublicKeyFixtures
  alias Astarte.RealmManagement.InterfaceFixtures
  alias Astarte.Core.Interface, as: InterfaceDocument
  alias Astarte.Core.InterfaceDescriptor
  alias Astarte.Core.CQLUtils
  alias Astarte.DataAccess.Consistency
  alias Astarte.DataAccess.Realms.Endpoint
  alias Astarte.DataAccess.Realms.Interface
  alias Astarte.DataAccess.Realms.IndividualProperty
  alias Astarte.DataAccess.Realms.IndividualDatastream
  alias Astarte.DataAccess.Realms.Realm
  alias Astarte.DataAccess.UUID
  alias Astarte.RealmManagement.DatabaseTestHelper
  alias Astarte.RealmManagement.Queries
  alias Astarte.RealmManagement.Repo

  describe "Test interface" do
    property "installed correctly", %{realm: realm} do
      check all intdoc <- Astarte.Core.Generators.Interface.interface() do
        %{
          name: interface_name,
          major_version: major_version,
          minor_version: minor_version
        } = InterfaceDescriptor.from_interface(intdoc)

        {:ok, automaton} = Astarte.Core.Mapping.EndpointsAutomaton.build(intdoc.mappings)

        Queries.install_new_interface(realm, intdoc, automaton)

        {:ok, interfaces} = Queries.get_interfaces_list(realm)

        assert interface_name in interfaces
      end
    end
  end

  describe "JWT public key" do
    test "updates with a vaild JWT", %{realm: realm} do
      new_pem = "not_exactly_a_PEM_but_will_do"
      assert :ok = Queries.update_jwt_public_key_pem(realm, new_pem)
      assert {:ok, new_pem} = Queries.get_jwt_public_key_pem(realm)

      pem = JWTPublicKeyFixtures.jwt_public_key_pem()

      # Put the PEM fixture back
      Queries.update_jwt_public_key_pem(realm, pem)

      assert {:ok, ^pem} = Queries.get_jwt_public_key_pem(realm)
    end
  end

  test "retrieve and delete individual datastreams for a device", %{realm: realm} do
    device_id = :crypto.strong_rand_bytes(16)
    interface_name = "com.an.individual.datastream.Interface"
    interface_major = 0
    endpoint = "/%{sensorId}/value"
    path = "/0/value"

    DatabaseTestHelper.seed_individual_datastream_test_data!(
      realm_name: realm,
      device_id: device_id,
      interface_name: interface_name,
      interface_major: interface_major,
      endpoint: endpoint,
      path: path
    )

    assert [
             %{
               device_id: ^device_id,
               interface_id: interface_id,
               endpoint_id: endpoint_id,
               path: ^path
             }
           ] =
             Queries.retrieve_individual_datastreams_keys!(
               realm,
               device_id
             )

    assert ^interface_id = CQLUtils.interface_id(interface_name, interface_major)

    assert ^endpoint_id = CQLUtils.endpoint_id(interface_name, interface_major, endpoint)

    assert :ok =
             Queries.delete_individual_datastream_values!(
               realm,
               device_id,
               interface_id,
               endpoint_id,
               path
             )

    assert [] =
             Queries.retrieve_individual_datastreams_keys!(
               realm,
               device_id
             )
  end

  test "retrieve and delete individual properties for a device", %{realm: realm} do
    device_id = :crypto.strong_rand_bytes(16)
    interface_name = "com.an.individual.property.Interface"
    interface_major = 0

    DatabaseTestHelper.seed_individual_properties_test_data!(
      realm_name: realm,
      device_id: device_id,
      interface_name: interface_name,
      interface_major: interface_major
    )

    assert [
             %{
               device_id: ^device_id,
               interface_id: interface_id
             }
           ] =
             Queries.retrieve_individual_properties_keys!(
               realm,
               device_id
             )

    assert ^interface_id = CQLUtils.interface_id(interface_name, interface_major)

    assert :ok =
             Queries.delete_individual_properties_values!(
               realm,
               device_id,
               interface_id
             )

    assert [] =
             Queries.retrieve_individual_properties_keys!(
               realm,
               device_id
             )
  end

  test "retrieve and delete object datastreams for a device", %{realm: realm} do
    interface_name = "com.object.datastream.Interface"
    interface_major = 0
    device_id = :crypto.strong_rand_bytes(16)
    path = "/0/value"

    table_name = CQLUtils.interface_name_to_table_name(interface_name, interface_major)
    DatabaseTestHelper.create_object_datastream_table!(realm, table_name)

    DatabaseTestHelper.seed_object_datastream_test_data!(
      realm_name: realm,
      device_id: device_id,
      interface_name: interface_name,
      interface_major: interface_major,
      path: path
    )

    assert [
             %{
               device_id: ^device_id,
               path: ^path
             }
           ] =
             Queries.retrieve_object_datastream_keys!(
               realm,
               device_id,
               table_name
             )

    assert :ok =
             Queries.delete_object_datastream_values!(
               realm,
               device_id,
               path,
               table_name
             )

    assert [] =
             Queries.retrieve_object_datastream_keys!(
               realm,
               device_id,
               table_name
             )
  end

  test "retrieve device introspection", %{realm: realm} do
    device_id = :crypto.strong_rand_bytes(16)
    interface_name = "com.an.object.datastream.Interface"
    interface_major = 0

    DatabaseTestHelper.add_interface_to_introspection!(
      realm_name: realm,
      device_id: device_id,
      interface_name: interface_name,
      interface_major: interface_major
    )

    assert %{^interface_name => ^interface_major} =
             Queries.retrieve_device_introspection_map!(
               realm,
               device_id
             )
  end

  test "retrieve interface from introspection", %{realm: realm} do
    interface_name = "com.an.object.datastream.Interface"
    interface_major = 0

    DatabaseTestHelper.seed_interfaces_table_object_test_data!(
      realm_name: realm,
      interface_name: interface_name,
      interface_major: interface_major
    )

    assert %Astarte.Core.InterfaceDescriptor{
             name: ^interface_name,
             major_version: ^interface_major
           } =
             Queries.retrieve_interface_descriptor!(
               realm,
               interface_name,
               interface_major
             )
  end

  test "retrieve and delete aliases", %{realm: realm} do
    device_id = :crypto.strong_rand_bytes(16)
    device_alias = "a boring device alias"

    DatabaseTestHelper.seed_aliases_test_data!(
      realm_name: realm,
      device_id: device_id,
      device_alias: device_alias
    )

    assert [
             %{
               object_name: ^device_alias
             }
           ] = Queries.retrieve_aliases!(realm, device_id)

    assert :ok =
             Queries.delete_alias_values!(
               realm,
               device_alias
             )

    assert [] = Queries.retrieve_aliases!(realm, device_id)
  end

  test "retrieve and delete groups", %{realm: realm} do
    device_id = :crypto.strong_rand_bytes(16)
    {insertion_uuid, _state} = :uuid.get_v1(:uuid.new(self()))
    group = "group"

    DatabaseTestHelper.seed_groups_test_data!(
      realm_name: realm,
      group_name: group,
      insertion_uuid: insertion_uuid,
      device_id: device_id
    )

    assert [
             %{
               device_id: ^device_id,
               insertion_uuid: ^insertion_uuid,
               group_name: ^group
             }
           ] = Queries.retrieve_groups_keys!(realm, device_id)

    assert :ok =
             Queries.delete_group_values!(
               realm,
               device_id,
               group,
               insertion_uuid
             )

    assert [] = Queries.retrieve_groups_keys!(realm, device_id)
  end

  test "retrieve and delete kv_store entries ", %{realm: realm} do
    interface_name = "com.an.individual.datastream.Interface"
    group = "devices-with-data-on-interface-#{interface_name}-v0"

    device_id = :crypto.strong_rand_bytes(16)
    encoded_device_id = Astarte.Core.Device.encode_device_id(device_id)

    DatabaseTestHelper.seed_kv_store_test_data!(
      realm_name: realm,
      group: group,
      key: encoded_device_id
    )

    assert [
             %{
               group: ^group,
               key: ^encoded_device_id
             }
           ] = Queries.retrieve_kv_store_entries!(realm, encoded_device_id)

    assert :ok =
             Queries.delete_kv_store_entry!(
               realm,
               group,
               encoded_device_id
             )

    assert [] = Queries.retrieve_kv_store_entries!(realm, encoded_device_id)
  end

  test "retrieve device registration limit for an existing realm ", %{realm: realm} do
    limit = 10

    DatabaseTestHelper.seed_realm_test_data!(
      realm_name: realm,
      device_registration_limit: limit
    )

    assert {:ok, ^limit} = Queries.get_device_registration_limit(realm)
  end

  test "fail to retrieve device registration limit if realm does not exist ", %{realm: realm} do
    realm_name = "realm#{System.unique_integer([:positive])}"
    assert {:error, :realm_not_found} = Queries.get_device_registration_limit(realm_name)
  end

  test "retrieve datastream_maximum_storage_retention for an existing realm ", %{realm: realm} do
    retention = 10

    DatabaseTestHelper.seed_realm_test_data!(
      realm_name: realm,
      datastream_maximum_storage_retention: retention
    )

    assert {:ok, ^retention} = Queries.get_datastream_maximum_storage_retention(realm)
  end

  test "fail to retrieve datastream_maximum_storage_retention if realm does not exist ", %{
    realm: realm
  } do
    realm_name = "realm#{System.unique_integer([:positive])}"

    assert_raise Xandra.Error, fn ->
      Queries.get_datastream_maximum_storage_retention(realm_name)
    end
  end
end
