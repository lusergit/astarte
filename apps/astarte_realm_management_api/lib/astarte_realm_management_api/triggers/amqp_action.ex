#
# This file is part of Astarte.
#
# Copyright 2020 Ispirata Srl
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

defmodule Astarte.RealmManagement.API.Triggers.AMQPAction do
  use Ecto.Schema
  import Ecto.Changeset
  alias Astarte.Core.Realm
  alias Astarte.RealmManagement.API.Triggers.AMQPAction

  @derive {Phoenix.Param, key: :realm_name}
  @primary_key false
  embedded_schema do
    field :realm_name, :string

    field :amqp_exchange, :string
    field :amqp_routing_key, :string
    field :amqp_message_expiration_ms, :integer
    field :amqp_message_priority, :integer
    field :amqp_message_persistent, :boolean
  end

  @mandatory_attrs [
    :realm_name,
    :amqp_exchange,
    :amqp_routing_key,
    :amqp_message_expiration_ms,
    :amqp_message_persistent
  ]
  @all_attrs [:amqp_message_priority | @mandatory_attrs]

  @doc false
  def changeset(%AMQPAction{} = amqp_action, %{"realm_name" => realm_name} = attrs) do
    amqp_action
    |> cast(attrs, @all_attrs)
    |> validate_required(@mandatory_attrs)
    |> validate_realm_name()
    |> validate_length(:amqp_exchange, max: 255, count: :bytes)
    |> validate_format(:amqp_exchange, ~r"^astarte_events_#{realm_name}_[a-zA-Z0-9_\.\:]+$")
    |> validate_length(:amqp_routing_key, max: 255, count: :bytes)
    |> validate_format(:amqp_routing_key, ~r"^[^{}]+$")
    |> validate_number(:amqp_message_expiration_ms, greater_than: 0)
    |> validate_inclusion(:amqp_message_priority, 0..9)
  end

  defp validate_realm_name(changeset) do
    validate_change(changeset, :realm_name, fn field, value ->
      if Realm.valid_name?(value) do
        []
      else
        [{field, "must be a valid realm name."}]
      end
    end)
  end

  defimpl Jason.Encoder, for: AMQPAction do
    def encode(action, opts) do
      %AMQPAction{
        amqp_exchange: amqp_exchange,
        amqp_routing_key: amqp_routing_key,
        amqp_message_expiration_ms: amqp_message_expiration_ms,
        amqp_message_persistent: amqp_message_persistent,
        amqp_message_priority: amqp_message_priority
      } = action

      %{
        "amqp_exchange" => amqp_exchange,
        "amqp_routing_key" => amqp_routing_key,
        "amqp_message_expiration_ms" => amqp_message_expiration_ms,
        "amqp_message_persistent" => amqp_message_persistent
      }
      |> maybe_put("amqp_message_priority", amqp_message_priority)
      |> Jason.Encode.map(opts)
    end

    defp maybe_put(map, _key, nil),
      do: map

    defp maybe_put(map, key, value),
      do: Map.put(map, key, value)
  end
end
