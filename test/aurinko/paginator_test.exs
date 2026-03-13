defmodule Aurinko.PaginatorTest do
  use ExUnit.Case, async: true

  alias Aurinko.{Paginator, Types.Pagination}

  @token "test_token"

  defp make_fetch_fn(pages) do
    counter = :counters.new(1, [])

    fn _token, opts ->
      idx = :counters.get(counter, 1)
      :counters.add(counter, 1, 1)

      page_token = Keyword.get(opts, :page_token)

      # Find the right page to return
      page =
        if is_nil(page_token) do
          Enum.at(pages, 0)
        else
          Enum.find(pages, fn p -> p.next_page_token == page_token or idx > 0 end) ||
            Enum.at(pages, idx)
        end

      if page, do: {:ok, page}, else: {:ok, %Pagination{records: [], next_page_token: nil}}
    end
  end

  describe "stream/3" do
    test "streams records from a single page" do
      pages = [
        %Pagination{records: ["a", "b", "c"], next_page_token: nil, next_delta_token: "delta"}
      ]

      records = Paginator.stream(@token, make_fetch_fn(pages)) |> Enum.to_list()
      assert records == ["a", "b", "c"]
    end

    test "streams records across multiple pages" do
      pages = [
        %Pagination{records: [1, 2, 3], next_page_token: "page2", next_delta_token: nil},
        %Pagination{records: [4, 5, 6], next_page_token: nil, next_delta_token: "delta"}
      ]

      fetch_fn = fn _token, opts ->
        case Keyword.get(opts, :page_token) do
          nil -> {:ok, Enum.at(pages, 0)}
          "page2" -> {:ok, Enum.at(pages, 1)}
          _ -> {:ok, %Pagination{records: [], next_page_token: nil}}
        end
      end

      records = Paginator.stream(@token, fetch_fn) |> Enum.to_list()
      assert records == [1, 2, 3, 4, 5, 6]
    end

    test "handles empty page list" do
      fetch_fn = fn _token, _opts ->
        {:ok, %Pagination{records: [], next_page_token: nil, next_delta_token: nil}}
      end

      records = Paginator.stream(@token, fetch_fn) |> Enum.to_list()
      assert records == []
    end

    test "halts stream on error when on_error: :halt" do
      fetch_fn = fn _token, _opts ->
        {:error, %Aurinko.Error{type: :server_error, message: "oops"}}
      end

      records = Paginator.stream(@token, fetch_fn, on_error: :halt) |> Enum.to_list()
      assert [{:error, _}] = records
    end

    test "skips errors when on_error: :skip" do
      fetch_fn = fn _token, _opts ->
        {:error, %Aurinko.Error{type: :server_error, message: "oops"}}
      end

      records = Paginator.stream(@token, fetch_fn, on_error: :skip) |> Enum.to_list()
      assert records == []
    end

    test "supports lazy evaluation with Stream.take" do
      call_count = :counters.new(1, [])

      fetch_fn = fn _token, _opts ->
        :counters.add(call_count, 1, 1)
        {:ok, %Pagination{records: [1, 2, 3, 4, 5], next_page_token: nil}}
      end

      records = Paginator.stream(@token, fetch_fn) |> Stream.take(3) |> Enum.to_list()
      assert records == [1, 2, 3]
      # Should only have fetched once
      assert :counters.get(call_count, 1) == 1
    end
  end

  describe "collect_all/3" do
    test "collects all records from all pages" do
      fetch_fn = fn _token, opts ->
        case Keyword.get(opts, :page_token) do
          nil -> {:ok, %Pagination{records: [:a, :b], next_page_token: "p2"}}
          "p2" -> {:ok, %Pagination{records: [:c, :d], next_page_token: nil}}
          _ -> {:ok, %Pagination{records: [], next_page_token: nil}}
        end
      end

      assert {:ok, [:a, :b, :c, :d]} = Paginator.collect_all(@token, fetch_fn)
    end

    test "returns error on API failure" do
      fetch_fn = fn _token, _opts ->
        {:error, %Aurinko.Error{type: :auth_error, message: "unauthorized"}}
      end

      assert {:error, %Aurinko.Error{type: :auth_error}} = Paginator.collect_all(@token, fetch_fn)
    end

    test "returns empty list for empty responses" do
      fetch_fn = fn _token, _opts ->
        {:ok, %Pagination{records: [], next_page_token: nil}}
      end

      assert {:ok, []} = Paginator.collect_all(@token, fetch_fn)
    end
  end

  describe "sync_stream/4" do
    test "streams records and calls on_delta with the final delta token" do
      delta_received = :ets.new(:delta_test, [:set, :public])

      fetch_fn = fn _token, _delta_or_page ->
        {:ok,
         %Pagination{
           records: ["msg1", "msg2"],
           next_page_token: nil,
           next_delta_token: "new_delta_token"
         }}
      end

      records =
        Paginator.sync_stream(@token, "initial_delta", fetch_fn,
          on_delta: fn tok -> :ets.insert(delta_received, {:token, tok}) end
        )
        |> Enum.to_list()

      assert records == ["msg1", "msg2"]
      assert [{:token, "new_delta_token"}] = :ets.lookup(delta_received, :token)
    end

    test "handles multiple pages within a sync batch" do
      call_count = :counters.new(1, [])

      fetch_fn = fn _token, token_value ->
        n = :counters.get(call_count, 1)
        :counters.add(call_count, 1, 1)

        case {n, token_value} do
          {0, _} ->
            {:ok, %Pagination{records: [1, 2], next_page_token: "page2", next_delta_token: nil}}

          {1, _} ->
            {:ok,
             %Pagination{records: [3, 4], next_page_token: nil, next_delta_token: "final_delta"}}

          _ ->
            {:ok, %Pagination{records: [], next_page_token: nil, next_delta_token: nil}}
        end
      end

      records = Paginator.sync_stream(@token, "delta_tok", fetch_fn) |> Enum.to_list()
      assert records == [1, 2, 3, 4]
    end
  end
end
