#
# This file is part of Astarte.
#
# Copyright 2018 - 2025 SECO Mind Srl
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

defmodule Astarte.RealmManagement.APIWeb.InterfaceControllerTest do
  use Astarte.RealmManagement.APIWeb.ConnCase, async: true

  @moduletag :interfaces

  alias Astarte.RealmManagement.API.Interfaces
  alias Astarte.RealmManagement.API.Helpers.JWTTestHelper
  alias Astarte.RealmManagement.API.Helpers.RPCMock.DB

  @interface_name "com.Some.Interface"
  @interface_major 0
  @interface_major_str Integer.to_string(@interface_major)
  @valid_attrs %{
    "interface_name" => @interface_name,
    "version_major" => @interface_major,
    "version_minor" => 2,
    "type" => "properties",
    "ownership" => "device",
    "mappings" => [
      %{
        "endpoint" => "/test",
        "type" => "integer"
      }
    ]
  }
  @invalid_attrs %{
    "interface_name" => @interface_name,
    "version_major" => 2,
    "version_minor" => 1,
    "type" => "INVALID",
    "ownership" => "device",
    "mappings" => [
      %{
        "endpoint" => "/test",
        "type" => "integer"
      }
    ]
  }

  setup %{conn: conn, realm: realm} do
    DB.put_jwt_public_key_pem(realm, JWTTestHelper.public_key_pem())
    token = JWTTestHelper.gen_jwt_all_access_token()

    conn =
      conn
      |> put_req_header("accept", "application/json")
      |> put_req_header("authorization", "Bearer #{token}")

    {:ok, conn: conn}
  end

  describe "index" do
    @describetag :index

    test "lists empty interfaces", %{conn: conn, realm: realm} do
      conn = get(conn, interface_path(conn, :index, realm))
      assert json_response(conn, 200)["data"] == []
    end

    test "lists interface after installing it", %{conn: conn, realm: realm} do
      # TODO: Remove all of this once all RPC calls are not needed anymore
      interface = Astarte.Core.Generators.Interface.interface() |> Enum.at(0)

      mappings =
        interface.mappings
        |> Enum.map(fn mapping ->
          mapping |> Map.put(:type, mapping.value_type)
        end)

      interface = Map.put(interface, :mappings, mappings)

      Mimic.expect(Astarte.RealmManagement.API.Interfaces, :install_interface, fn ^realm,
                                                                                  params,
                                                                                  opts ->
        assert params == interface
        assert opts == [async: true]

        db_interface = %Astarte.Core.Interface{
          name: params.name,
          major_version: params.major_version
        }

        DB.install_interface(realm, db_interface)
        {:ok, interface}
      end)

      post_conn = post(conn, interface_path(conn, :create, realm), data: interface)
      assert response(post_conn, 201) == ""

      list_conn = get(conn, interface_path(conn, :index, realm))
      assert json_response(list_conn, 200)["data"] == [interface.name]
    end
  end

  describe "show" do
    @describetag :show

    test "shows existing interface", %{conn: conn, realm: realm} do
      # TODO: Remove all of this once all RPC calls are not needed anymore
      interface = Astarte.Core.Generators.Interface.interface() |> Enum.at(0) |> to_struct()

      Mimic.expect(Astarte.RealmManagement.API.Interfaces, :install_interface, fn ^realm,
                                                                                  params,
                                                                                  _ ->
        db_interface = %Astarte.Core.Interface{
          name: params.name,
          major_version: params.major_version
        }

        DB.install_interface(realm, db_interface)
        {:ok, interface}
      end)

      post_conn = post(conn, interface_path(conn, :create, realm), data: interface)
      assert response(post_conn, 201) == ""

      show_conn =
        get(conn, interface_path(conn, :show, realm, interface.name, interface.major_version))

      assert json_response(show_conn, 200)["data"]["interface_name"] == interface.name
    end

    test "renders error on non-existing interface", %{conn: conn, realm: realm} do
      conn =
        get(conn, interface_path(conn, :show, realm, "com.Nonexisting", @interface_major_str))

      assert json_response(conn, 404)["errors"] != %{}
    end
  end

  describe "create interface" do
    @describetag :creation

    test "Installs an interface with valid data", %{conn: conn, realm: realm} do
      # TODO: Remove all of this once all RPC calls are not needed anymore
      interface = Astarte.Core.Generators.Interface.interface() |> Enum.at(0) |> Map.from_struct()

      mappings =
        interface.mappings
        |> Enum.map(fn mapping ->
          mapping |> Map.from_struct() |> Map.put(:type, mapping.value_type)
        end)

      interface = Map.put(interface, :mappings, mappings)

      post_conn =
        post(conn, interface_path(conn, :create, realm),
          data: interface,
          async_operation: "false"
        )

      assert response(post_conn, 201) == ""
    end

    test "errors on an already installed interface", %{conn: conn, realm: realm} do
      # TODO: Remove all of this once all RPC calls are not needed anymore
      interface = Astarte.Core.Generators.Interface.interface() |> Enum.at(0) |> Map.from_struct()

      mappings =
        interface.mappings
        |> Enum.map(fn mapping ->
          mapping |> Map.from_struct() |> Map.put(:type, mapping.value_type)
        end)

      interface = Map.put(interface, :mappings, mappings)

      conn =
        conn
        |> post(interface_path(conn, :create, realm),
          data: interface,
          async_operation: "false"
        )
        |> post(interface_path(conn, :create, realm),
          data: interface,
          async_operation: "false"
        )

      assert json_response(conn, 409)["errors"] != %{}
    end

    test "renders error on mapping with higher database_retention_ttl than the maximum", %{
      conn: conn,
      realm: realm
    } do
      # TODO: Remove all of this once all RPC calls are not needed anymore
      interface =
        Astarte.Core.Generators.Interface.interface(
          type: :datastream,
          database_retention_policy: :use_ttl
        )
        |> Enum.at(0)
        |> Map.from_struct()

      mappings =
        interface.mappings
        |> Enum.map(fn mapping ->
          mapping
          |> Map.from_struct()
          |> Map.put(:type, mapping.value_type)
          |> Map.put(:database_retention_ttl, 1000)
          |> Map.put(:database_retention_policy, :use_ttl)
        end)

      interface =
        Map.put(interface, :mappings, mappings)

      insert_datastream_maximum_storage_retention!(realm, 10)

      conn =
        conn
        |> post(interface_path(conn, :create, realm),
          data: interface,
          async_operation: "false"
        )

      assert json_response(conn, 422)["errors"] != %{}
    end

    test "fails when interface name collides after normalization", %{conn: conn, realm: realm} do
      interface_name = "com.astarteplatform.Interface"

      first_attrs =
        @valid_attrs
        |> Map.put("interface_name", interface_name)

      post_conn =
        post(conn, interface_path(conn, :create, realm),
          data: first_attrs,
          async_operation: "false"
        )

      assert response(post_conn, 201) == ""

      colliding_name = "com.astarte-platform.Interface"

      colliding_attrs =
        @valid_attrs
        |> Map.put("interface_name", colliding_name)

      post_conn =
        post(conn, interface_path(conn, :create, realm),
          data: colliding_attrs,
          async_operation: "false"
        )

      assert json_response(post_conn, 409)["errors"] != %{}
    end
  end

  describe "update" do
    @describetag :update

    setup %{realm: realm} do
      interface = Astarte.Core.Generators.Interface.interface() |> Enum.at(0) |> to_struct()

      {:ok, interface} =
        Interfaces.install_interface(realm, interface)

      DB.install_interface(realm, interface)

      %{interface: interface}
    end

    test "updates interface when data is valid", %{conn: conn, realm: realm, interface: interface} do
      new_mapping = %{endpoint: "/other", type: "string"}
      new_minor = interface.minor_version + 1

      update =
        interface
        |> to_params()
        |> Map.put("minor_version", new_minor)

      update = Map.put(update, "mappings", [new_mapping | update["mappings"]])

      update_conn =
        put(
          conn,
          interface_path(
            conn,
            :update,
            realm,
            interface.name,
            interface.major_version
          ),
          data: update
        )

      assert response(update_conn, 204)

      get_conn =
        get(conn, interface_path(conn, :show, realm, interface.name, interface.major_version))

      assert json_response(get_conn, 200)["data"] == update
    end

    test "renders errors when data is invalid", %{conn: conn, realm: realm} do
      conn =
        put(
          conn,
          interface_path(conn, :update, realm, @interface_name, @interface_major_str),
          data: @invalid_attrs
        )

      assert json_response(conn, 422)["errors"] != %{}
    end

    test "renders error when major is not a number", %{conn: conn, realm: realm} do
      conn =
        put(
          conn,
          interface_path(conn, :update, realm, @interface_name, "notanumber"),
          data: @valid_attrs
        )

      assert json_response(conn, 404)["errors"] != %{}
    end

    test "renders error when name doesn't match", %{conn: conn, realm: realm} do
      conn =
        put(
          conn,
          interface_path(conn, :update, realm, "com.Other.Interface", @interface_major_str),
          data: @valid_attrs
        )

      assert json_response(conn, 409)["errors"] != %{}
    end

    test "renders error when major doesn't match", %{conn: conn, realm: realm} do
      conn =
        put(
          conn,
          interface_path(conn, :update, realm, @interface_name, "42"),
          data: @valid_attrs
        )

      assert json_response(conn, 409)["errors"] != %{}
    end

    test "renders error when interface doesn't exist", %{conn: conn, realm: realm} do
      other_interface = "com.Other"
      attrs = %{@valid_attrs | "interface_name" => other_interface}

      conn =
        put(
          conn,
          interface_path(conn, :update, realm, other_interface, @interface_major_str),
          data: attrs
        )

      assert json_response(conn, 404)["errors"] != %{}
    end

    test "renders error when minor version is not increased", %{conn: conn, realm: realm} do
      new_mapping = %{"endpoint" => "/other", "type" => "string"}
      updated_mappings = [new_mapping | @valid_attrs["mappings"]]

      update_attrs = %{
        @valid_attrs
        | "mappings" => updated_mappings
      }

      update_conn =
        put(
          conn,
          interface_path(conn, :update, realm, @interface_name, @interface_major_str),
          data: update_attrs
        )

      assert json_response(update_conn, 409)["errors"]["detail"] ==
               "Interface minor version was not increased"
    end

    test "renders error minor version is decreased", %{conn: conn, realm: realm} do
      new_mapping = %{"endpoint" => "/other", "type" => "string"}
      updated_mappings = [new_mapping | @valid_attrs["mappings"]]
      new_minor = @valid_attrs["version_minor"] - 1

      update_attrs = %{
        @valid_attrs
        | "version_minor" => new_minor,
          "mappings" => updated_mappings
      }

      update_conn =
        put(
          conn,
          interface_path(conn, :update, realm, @interface_name, @interface_major_str),
          data: update_attrs
        )

      assert json_response(update_conn, 409)["errors"]["detail"] ==
               "Interface downgrade not allowed"
    end

    test "renders error when mappings have missing endpoints", %{conn: conn, realm: realm} do
      update_attrs = %{
        @valid_attrs
        | "version_minor" => @valid_attrs["version_minor"] + 1,
          "mappings" => [
            %{
              "endpoint" => "/new_endpoint",
              "type" => "integer"
            }
          ]
      }

      update_conn =
        put(
          conn,
          interface_path(conn, :update, realm, @interface_name, @interface_major_str),
          data: update_attrs
        )

      assert json_response(update_conn, 409)["errors"]["detail"] ==
               "Interface update has missing endpoints"
    end

    test "renders error when mappings have incompatible changes", %{conn: conn, realm: realm} do
      update_attrs = %{
        @valid_attrs
        | "version_minor" => @valid_attrs["version_minor"] + 1,
          "mappings" => [
            %{
              "endpoint" => "/test",
              # Changing the type from integer to string
              "type" => "string"
            }
          ]
      }

      update_conn =
        put(
          conn,
          interface_path(conn, :update, realm, @interface_name, @interface_major_str),
          data: update_attrs
        )

      assert json_response(update_conn, 409)["errors"]["detail"] ==
               "Interface update contains incompatible endpoint changes"
    end

    test "renders error when type changes", %{conn: conn, realm: realm} do
      update_attrs = %{
        @valid_attrs
        | "version_minor" => @valid_attrs["version_minor"] + 1,
          # Changed type
          "type" => "datastream"
      }

      update_conn =
        put(
          conn,
          interface_path(conn, :update, realm, @interface_name, @interface_major_str),
          data: update_attrs
        )

      assert json_response(update_conn, 409)["errors"]["detail"] == "Invalid update"
    end

    test "renders error when ownership changes", %{conn: conn, realm: realm} do
      update_attrs = %{
        @valid_attrs
        | "version_minor" => @valid_attrs["version_minor"] + 1,
          # Changed ownership
          "ownership" => "server"
      }

      update_conn =
        put(
          conn,
          interface_path(conn, :update, realm, @interface_name, @interface_major_str),
          data: update_attrs
        )

      assert json_response(update_conn, 409)["errors"]["detail"] ==
               "Invalid update"
    end
  end

  describe "delete" do
    @describetag :deletion

    test "deletes existing interface", %{conn: conn, realm: realm} do
      post_conn = post(conn, interface_path(conn, :create, realm), data: @valid_attrs)
      assert response(post_conn, 201) == ""

      delete_conn =
        delete(conn, interface_path(conn, :delete, realm, @interface_name, @interface_major_str))

      assert response(delete_conn, 204) == ""
    end

    test "fails if major version is other than 0", %{conn: conn, realm: realm} do
      new_interface_major = 1

      major_attrs =
        @valid_attrs
        |> Map.put("version_major", new_interface_major)

      post_conn = post(conn, interface_path(conn, :create, realm), data: major_attrs)
      assert response(post_conn, 201) == ""

      delete_conn =
        delete(
          conn,
          interface_path(
            conn,
            :delete,
            realm,
            @interface_name,
            Integer.to_string(new_interface_major)
          )
        )

      assert json_response(delete_conn, 403)["errors"]["detail"] ==
               "Interface can't be deleted"
    end

    test "renders error on non-existing interface", %{conn: conn, realm: realm} do
      delete_conn =
        delete(
          conn,
          interface_path(conn, :delete, realm, "com.Nonexisting", @interface_major_str)
        )

      assert json_response(delete_conn, 404)["errors"] != %{}
    end
  end

  defp to_struct(interface) do
    interface
    |> Map.from_struct()
    |> Map.put(
      :mappings,
      Enum.map(interface.mappings, fn mapping ->
        mapping |> Map.from_struct() |> Map.put(:type, mapping.value_type)
      end)
    )
  end

  defp to_params(interface) do
    %{
      "interface_name" => interface.name,
      "version_major" => interface.major_version,
      "version_minor" => interface.minor_version,
      "type" => interface.type,
      "ownership" => interface.ownership,
      "mappings" => to_params_mappings(interface.mappings)
    }
  end

  defp to_params_mappings(mappings) do
    Enum.map(mappings, fn mapping ->
      %{
        "endpoint" => mapping.endpoint,
        "type" => mapping.value_type,
        "reliability" => mapping.reliability,
        "retention" => mapping.retention,
        "expiry" => mapping.expiry,
        "database_retention_ttl" => mapping.database_retention_ttl,
        "database_retention_policy" => mapping.database_retention_policy,
        "allow_unset" => mapping.allow_unset,
        "explicit_timestamp" => mapping.explicit_timestamp,
        "description" => mapping.description,
        "doc" => mapping.doc
      }
    end)
  end
end
