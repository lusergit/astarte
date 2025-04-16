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

defmodule Astarte.RealmManagement.JwtTest do
  alias Astarte.RealmManagement.Engine

  use Astarte.RealmManagement.DataCase, async: true
  use ExUnitProperties

  describe "Test JWT PEM" do
    @describetag :jwt
    test "is correctly updated and fetched", %{realm: realm} do
      {:ok, old_jwt} = Engine.get_jwt_public_key_pem(realm)

      new_jwt = "not_exactly_a_jwt_but_will_do"
      :ok = Engine.update_jwt_public_key_pem(realm, new_jwt)

      {:ok, jwt} = Engine.get_jwt_public_key_pem(realm)

      assert new_jwt == jwt
    end
  end
end
