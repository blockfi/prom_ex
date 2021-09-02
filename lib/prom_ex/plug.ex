defmodule PromEx.Plug do
  @moduledoc """
  Use this plug in your Endpoint file to expose your metrics. The following options are supported by this plug:

  * `:prom_ex_module` - The PromEx module/modules whose metrics will be published through this particular plug
  * `:path` - The path through which your metrics can be accessed (default is "/metrics")

  ```elixir
  plug PromEx.Plug, prom_ex_module: YourApp.PromEx
  ```

  ```elixir
  plug PromEx.Plug, prom_ex_module: [YourFirstApp.PromEx, YourSecondApp.PromEx]
  ```

  If you need to have some sort of access control around your metrics endpoint, I would suggest looking at another
  library that I maintain called `Unplug` (https://hex.pm/packages/unplug). Using `Unplug`, you can skip over this plug
  if some sort of requirement is not fulfilled. For example, if you wanted to configure the metrics endpoint to
  only be accessible if the request has an Authorization header that matches a configured environment variable you
  could do something like so using `Unplug`:

  ```elixir
  defmodule MyApp.UnplugPredicates.SecureMetricsEndpoint do
    @behaviour Unplug.Predicate

    @impl true
    def call(conn, env_var) do
      auth_header = Plug.Conn.get_req_header(conn, "authorization")

      System.get_env(env_var) == auth_header
    end
  end
  ```

  Which can then be used in your `endpoint.ex` file like so:

  ```elixir
  plug Unplug,
    if: {MyApp.UnplugPredicates.SecureMetricsEndpoint, "PROMETHEUS_AUTH_SECRET"},
    do: {PromEx.Plug, prom_ex_module: MyApp.PromEx}
  ```

  The reason that this functionality is not part of PromEx itself is that how you chose to configure the visibility
  of the metrics route is entirely up to the user and so it felt as though this plug would be over complicated by
  having to support application config, environment variables, etc. And given that `Unplug` exists for this purpose,
  it is the recommended tool for the job.
  """

  @behaviour Plug

  require Logger

  import Plug.Conn

  alias Plug.Conn

  @impl true
  def init(opts) do
    %{
      prom_ex_module: Keyword.fetch!(opts, :prom_ex_module),
      metrics_path: Keyword.get(opts, :path, "/metrics")
    }
  end

  @impl true
  def call(%Conn{request_path: metrics_path} = conn, %{metrics_path: metrics_path, prom_ex_module: prom_ex_module})
      when is_list(prom_ex_module) do
    metrics =
      Enum.reduce(prom_ex_module, "", fn module, acc ->
        case get_metrics(module) do
          {:ok, metrics} -> acc <> metrics
          {:error, _} -> acc <> ""
        end
      end)

    case metrics do
      "" -> respond(conn, 503, "Service Unavailable")
      metrics -> respond(conn, 200, metrics)
    end
  end

  @impl true
  def call(%Conn{request_path: metrics_path} = conn, %{metrics_path: metrics_path, prom_ex_module: prom_ex_module}) do
    case get_metrics(prom_ex_module) do
      {:ok, metrics} -> respond(conn, 200, metrics)
      {:error, error} -> respond(conn, 503, error)
    end
  end

  def call(conn, _opts) do
    conn
  end

  defp get_metrics(prom_ex_module) do
    case PromEx.get_metrics(prom_ex_module) do
      :prom_ex_down ->
        Logger.warn("Attempted to fetch metrics from #{prom_ex_module}, but the module has not been initialized")

        {:error, "Service Unavailable"}

      metrics ->
        PromEx.ETSCronFlusher.defer_ets_flush(prom_ex_module.__ets_cron_flusher_name__())

        {:ok, metrics}
    end
  end

  defp respond(conn, status, response) do
    conn
    |> put_resp_content_type("text/plain")
    |> send_resp(status, response)
    |> halt()
  end
end
