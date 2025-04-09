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

defmodule Astarte.RealmManagement.InterfaceFixtures do
  @moduledoc """
  This module defines interfaces fixtures for creating `Astarte.Core.Interface`.
  """
  alias Astarte.Core.Interface

  @object_datastream_interface_json """
  {
   "interface_name": "com.ispirata.Hemera.DeviceLog",
   "version_major": 1,
   "version_minor": 0,
   "type": "datastream",
   "quality": "producer",
   "aggregate": true,
   "mappings": [
       {
           "path": "/message",
           "type": "string",
           "reliability": "guaranteed",
           "retention": "stored"
       },
       {
           "path": "/timestamp",
           "type": "datetime",
           "reliability": "guaranteed",
           "retention": "stored"
       },
       {
           "path": "/monotonicTimestamp",
           "type": "longinteger",
           "reliability": "guaranteed",
           "retention": "stored"
       },
       {
           "path": "/applicationId",
           "type": "string",
           "reliability": "guaranteed",
           "retention": "stored"
       },
       {
           "path": "/pid",
           "type": "integer",
           "reliability": "guaranteed",
           "retention": "stored"
       },
       {
           "path": "/cmdLine",
           "type": "string",
           "reliability": "guaranteed",
           "retention": "stored"
       }
   ]
  }
  """

  @individual_property_device_owned_interface """
  {
       "interface_name": "com.ispirata.Hemera.DeviceLog.Status",
       "version_major": 2,
       "version_minor": 1,
       "type": "properties",
       "quality": "producer",
       "mappings": [
           {
               "path": "/filterRules/%{ruleId}/%{filterKey}/value",
               "type": "string",
               "allow_unset": true
           }
       ]
  }
  """

  def object_datastream_interface() do
    json_obj = Jason.decode!(@object_datastream_interface_json)

    %Interface{}
    |> Interface.changeset(json_obj)
    |> Ecto.Changeset.apply_action!(:insert)
  end

  def individual_property_device_owned_interface() do
    json_obj = Jason.decode!(@individual_property_device_owned_interface)

    %Interface{}
    |> Interface.changeset(json_obj)
    |> Ecto.Changeset.apply_action!(:insert)
  end
end
