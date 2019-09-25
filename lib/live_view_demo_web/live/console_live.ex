defmodule LiveViewDemoWeb.ConsoleLive do
  use Phoenix.LiveView
  import Phoenix.HTML, only: [sigil_e: 2]

  @console_buffer 100

  defmodule Output do
    @enforce_keys [:command]
    defstruct [:command, :result, :error]
  end

  def render(assigns) do
    ~L"""
    <div class="flex h-full flex-col sm:flex-row">
      <div class="flex-1 sm:h-full overflow-scroll">
        <form phx-submit="execute" class="h-full flex flex-col">
          <div class="flex-1"></div>
          <div class="p-2">
            <%= for output <- @output do %>
              <div class="text-gray-300 font-medium"><%= print_prompt() %><%= format_command(output.command) %></div>
              <div class="text-teal-300">
                <%= if output.result do output.result end %>
                <%= if output.error do %><span class="text-pink-400"><%= output.error %></span><% end %>
              </div>
            <% end %>
          </div>
          <div class="text-gray-300 font-medium flex bg-teal-700 p-2">
            <%= print_prompt() %>
            <input
              type="text"
              id="commandInput"
              class="ml-2 bg-transparent flex-1 outline-none"
              autocomplete="off"
              name="command"
              phx-keydown="suggest"
              phx-hook="CommandInput"
              data-input_value="<%= @input_value %>"
            />
          </div>
        </form>
      </div>
      <div class="w-full sm:w-32 md:w-1/3 h-32 sm:h-full bg-teal-800 p-2 text-gray-300 overflow-scroll flex flex-col">
        <h2 class="font-medium">Current Variables</h2>
        <ul>
          <%= for {key, value} <- @bindings do %>
            <li><%= key %>: <code class="text-teal-300"><%= inspect(value) %></code></li>
          <% end %>
        </ul>
        <div class="flex-1"></div>
        <%= if @suggestions != [] do %>
          <h2 class="font-medium">Suggestions:</h2>
        <% else %>
          <%= if @show_contextual_info do %>
            <span class="mb-8 font-bold text-green-400"><%= @show_contextual_info[:header] %></span>
            <span class="text-xs text-green-400"><%= Phoenix.HTML.raw @show_contextual_info[:doc] %></span>
          <% else %>
            <p>[TAB]: suggestions</p>
          <% end %>
        <% end %>
        <ul>
          <%= for suggestion <- @suggestions do %>
            <li><%= suggestion %></li>
          <% end %>
        </ul>
      </div>
    </div>
    """
  end

  def mount(_session, socket) do
    {:ok,
     assign(
       socket,
       output: [],
       bindings: [],
       history: [],
       history_counter: 0,
       suggestions: [],
       input_value: "",
       show_contextual_info: nil
     )}
  end

  # TAB KEY
  def handle_event("suggest", %{"keyCode" => 9, "value" => value}, socket) do
    last_word = String.split(value) |> List.last() || ""

    suggestions =
      socket.assigns.bindings
      |> Enum.map(fn {name, _} -> Atom.to_string(name) end)
      |> Enum.filter(&String.starts_with?(&1, last_word))

    case suggestions do
      [suggestion] ->
        new_input = Regex.replace(~r/\.*#{last_word}$/, value, suggestion)
        {:noreply, socket |> assign(input_value: new_input, suggestions: [])}

      suggestions ->
        {:noreply, socket |> assign(suggestions: suggestions, input_value: "")}
    end
  end

  # KEY UP
  def handle_event("suggest", %{"keyCode" => 38}, socket) do
    counter = socket.assigns.history_counter
    history = socket.assigns.history

    {input_value, new_counter} =
      cond do
        history == [] ->
          {[], 0}

        counter + 1 < length(history) ->
          {[Enum.at(history, counter + 1)], counter + 1}

        counter + 1 >= length(history) ->
          {[List.last(history)], counter}
      end

    {:noreply, socket |> assign(input_value: input_value, history_counter: new_counter)}
  end

  # KEY DOWN
  def handle_event("suggest", %{"keyCode" => 40}, socket) do
    counter = socket.assigns.history_counter
    history = socket.assigns.history

    {input_value, new_counter} =
      cond do
        history == [] ->
          {[], 0}

        counter > 0 ->
          {[Enum.at(history, counter - 1)], counter - 1}

        counter <= 0 ->
          {[List.first(history)], 0}
      end

    {:noreply, socket |> assign(input_value: input_value, history_counter: new_counter)}
  end

  def handle_event("suggest", _key, socket) do
    {:noreply, socket |> assign(history_counter: -1)}
  end

  def handle_event("execute", %{"command" => command}, socket) do
    history =
      if socket.assigns.history == [] do
        [command]
      else
        [command | socket.assigns.history]
      end

    case execute_command(command, socket.assigns.bindings) do
      {:ok, result, bindings} ->
        {:noreply,
         socket
         |> append_output(:ok, command, result)
         |> assign(bindings: bindings)
         |> assign(history: history)
         |> assign(suggestions: [])
         |> assign(input_value: "")
         |> assign(show_contextual_info: nil)}

      {:error, error} ->
        {:noreply,
         socket
         |> append_output(:error, command, error)
         |> assign(history: history)
         |> assign(suggestions: [])
         |> assign(input_value: "")
         |> assign(show_contextual_info: nil)}
    end
  end

  def handle_event("show_contextual_info", %{"header" => header, "doc" => doc}, socket) do
    {:noreply,
     socket
     |> assign(show_contextual_info: %{header: header, doc: doc})
     |> assign(suggestions: [])}
  end

  defp execute_command(command, bindings) do
    {result, bindings} = Code.eval_string(command, bindings)
    {:ok, inspect(result), bindings}
  catch
    kind, error ->
      error = Exception.normalize(kind, error)
      {:error, inspect(error)}
  end

  defp append_output(socket, status, command, result_or_error) do
    new_output = socket.assigns.output ++ [build_output(status, command, result_or_error)]
    new_output = Enum.take(new_output, -@console_buffer)
    assign(socket, output: new_output)
  end

  defp build_output(:ok, command, result), do: %Output{command: command, result: result}
  defp build_output(:error, command, error), do: %Output{command: command, error: error}

  defp print_prompt, do: "> "

  defp format_command(command) do
    for part <- splitted_command(command) do
      case part do
        {part, help_metadata} ->
          render_command_inline_help(part, help_metadata)

        part ->
          part
      end
    end
  end

  defp splitted_command(command) do
    LiveViewDemo.ContextualHelp.compute(command)
  end

  defp render_command_inline_help(part, %{header: header, docs: docs}) do
    ~e{<span
      phx-click="show_contextual_info"
      phx-value-header="<%= header %>"
      phx-value-doc="<%= docs %>"
      class="text-green-400 cursor-pointer underline"
    ><%= part %></span>}
  end
end
