defmodule Tesla.MockTest do
  use ExUnit.Case

  defmodule Client do
    use Tesla
    plug Tesla.Middleware.JSON
  end

  Application.put_env(:tesla, Tesla.MockTest.Client, adapter: Tesla.Mock)

  import Tesla.Mock

  defp setup_mock(_) do
    mock(fn
      %{url: "/ok-tuple"} ->
        {:ok, %Tesla.Env{status: 200, body: "hello tuple"}}

      %{url: "/tuple"} ->
        {201, [{"content-type", "application/json"}], ~s"{\"id\":42}"}

      %{url: "/env"} ->
        %Tesla.Env{status: 200, body: "hello env"}

      %{url: "/error"} ->
        {:error, :some_error}

      %{url: "/other"} ->
        :econnrefused

      %{url: "/json"} ->
        json(%{json: 123})

      %{method: :post, url: "/match-body", body: ~s({"some":"data"})} ->
        {201, [{"content-type", "application/json"}], ~s"{\"id\":42}"}
    end)

    :ok
  end

  describe "with mock" do
    setup :setup_mock

    test "raise on unmocked request" do
      assert_raise Tesla.Mock.Error, fn ->
        Client.get("/unmocked")
      end
    end

    test "return {:ok, env} tuple" do
      assert {:ok, %Tesla.Env{} = env} = Client.get("/ok-tuple")
      assert env.status == 200
      assert env.body == "hello tuple"
    end

    test "return {status, headers, body} tuple" do
      assert {:ok, %Tesla.Env{} = env} = Client.get("/tuple")
      assert env.status == 201
      assert env.headers == [{"content-type", "application/json"}]
      assert env.body == %{"id" => 42}
    end

    test "return env" do
      assert {:ok, %Tesla.Env{} = env} = Client.get("/env")
      assert env.status == 200
      assert env.body == "hello env"
    end

    test "return {:error, reason} tuple" do
      assert {:error, :some_error} = Client.get("/error")
    end

    test "return other error" do
      assert {:error, :econnrefused} = Client.get("/other")
    end

    test "return json" do
      assert {:ok, %Tesla.Env{} = env} = Client.get("/json")
      assert env.status == 200
      assert env.body == %{"json" => 123}
    end

    test "mock post request" do
      assert {:ok, %Tesla.Env{} = env} = Client.post("/match-body", %{"some" => "data"})
      assert env.status == 201
      assert env.body == %{"id" => 42}
    end

    test "mock a request inside a child process" do
      child_task =
        Task.async(fn ->
          assert {:ok, %Tesla.Env{} = env} = Client.get("/json")
          assert env.status == 200
          assert env.body == %{"json" => 123}
        end)

      Task.await(child_task)
    end

    test "mock a request inside a grandchild process" do
      grandchild_task =
        Task.async(fn ->
          child_task =
            Task.async(fn ->
              assert {:ok, %Tesla.Env{} = env} = Client.get("/json")
              assert env.status == 200
              assert env.body == %{"json" => 123}
            end)

          Task.await(child_task)
        end)

      Task.await(grandchild_task)
    end
  end

  describe "supervised task" do
    test "allows mocking in the caller process" do
      # in real apps, task supervisor will be part of the supervision tree
      # and it won't be an ancestor of the test process
      # to simulate that, we will set the mock in a task
      #
      # test_process
      # |-mocking_task will set the mock and create the supervised task
      # `-task supervisor
      #   `- supervised_task
      # this way, mocking_task is not an $ancestor of the supervised_task
      # but it is $caller
      {:ok, supervisor_pid} = start_supervised(Task.Supervisor, restart: :temporary)

      mocking_task =
        Task.async(fn ->
          mock(fn
            %{url: "/callers-test"} ->
              {:ok, %Tesla.Env{status: 200, body: "callers work"}}
          end)

          supervised_task =
            Task.Supervisor.async(supervisor_pid, fn ->
              assert {:ok, %Tesla.Env{} = env} = Client.get("/callers-test")
              assert env.status == 200
              assert env.body == "callers work"
            end)

          Task.await(supervised_task)
        end)

      Task.await(mocking_task)
    end
  end

  describe "agent" do
    defmodule MyAgent do
      use Agent

      def start_link(_arg) do
        Agent.start_link(fn -> Client.get!("/ancestors-test") end, name: __MODULE__)
      end
    end

    # TODO: the standard way is to just look in $callers.
    # However, we were using $ancestors before and users were depending on that behaviour
    # https://github.com/elixir-tesla/tesla/issues/765
    # To make sure we don't break existing flows,
    # we will check mocks *both* in $callers and $ancestors
    # We might want to remove checking in $ancestors in a major release
    test "allows mocking in the ancestor" do
      mock(fn
        %{url: "/ancestors-test"} ->
          {:ok, %Tesla.Env{status: 200, body: "ancestors work"}}
      end)

      {:ok, _pid} = MyAgent.start_link([])
    end
  end

  describe "without mock" do
    test "raise on unmocked request" do
      assert_raise Tesla.Mock.Error, fn ->
        Client.get("/return-env")
      end
    end
  end

  describe "json/2" do
    test "defaults" do
      assert %Tesla.Env{status: 200, headers: [{"content-type", "application/json"}]} =
               json("data")
    end

    test "custom status" do
      assert %Tesla.Env{status: 404} = json("data", status: 404)
    end
  end
end
