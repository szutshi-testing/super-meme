package main

import "fmt"

func main() {
    message := "Hello, world!"
    fmt.Println(message)

    result := add(5, "10") // Error: mismatched types, string passed instead of int
    fmt.Println("Sum is:", result)

    for i := 0; i < 5; i++ {
        fmt.Println("Count:", i)

    // Missing closing brace for the for-loop
}

func add(a int, b int) int {
    return a + b
}
