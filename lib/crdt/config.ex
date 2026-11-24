defmodule Crdt.Config do
  @moduledoc "Reads an optional static node table from the file in NODES_FILE."

  @doc """
  Returns `{:ok, file, nodes}` with the names as atoms, or `{:error, file, reason}`.
  If NODES_FILE is unset, `{:ok, "none", []}`.
  """
  def nodes do
    case System.get_env("NODES_FILE") do
      nil -> {:ok, "none", []}
      file -> read(file)
    end
  end

  defp read(file) do
    case File.read(file) do
      {:ok, text} -> {:ok, file, parse(text)}
      {:error, reason} -> {:error, file, reason}
    end
  end

  defp parse(text) do
    for line <- String.split(text, "\n"),
        name = String.trim(line),
        name != "" and not String.starts_with?(name, "#"),
        do: String.to_atom(name)
  end
end
